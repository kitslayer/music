import AVFoundation
import Foundation

/// Taps the PCM coming out of an `AVPlayerItem`, so streamed tracks can be visualised.
///
/// `AVPlayer` exposes no Swift-level way to see samples; `MTAudioProcessingTap` is the
/// only route, and it is a C API with five function-pointer callbacks. Every constraint
/// below is real, and getting any of them wrong shows up as silence or a crash rather
/// than as a compile error:
///
/// - The callbacks must be `@convention(c)`, so they **cannot capture** anything. The
///   only channel to Swift state is the `clientInfo` pointer, retained on create and
///   released in `finalize`.
/// - `process` runs on a **real-time audio thread**. It does one `memcpy` into a
///   preallocated ring and nothing else — no allocation, no locking, no `Task`.
/// - It must call `MTAudioProcessingTapGetSourceAudio` and leave the buffers alone.
///   This is a passthrough tap: it observes, it never modifies, so a mistake here
///   cannot alter the audio, only fail to see it.
/// - The tap is created `PostEffects` so what is measured is what is heard.
enum AudioTap {
    /// Builds an `AVAudioMix` that feeds `buffer`, or nil if anything at all goes wrong.
    ///
    /// Returning nil rather than throwing is deliberate: playback must never depend on
    /// the visualiser succeeding, so every caller treats failure as "no bars" and
    /// carries on.
    static func makeMix(for track: AVAssetTrack, feeding buffer: AudioSampleBuffer) -> AVAudioMix? {
        // Retained here, balanced by the release in `finalize`. An unretained pointer is
        // the classic way this crashes minutes into playback.
        let clientInfo = Unmanaged.passRetained(buffer).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(clientInfo),
            init: { _, clientInfo, tapStorageOut in
                // Hand the buffer pointer straight through to tap storage; `process`
                // reads it from there.
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                guard let storage = MTAudioProcessingTapGetStorage(tap) else { return }
                let buffer = Unmanaged<AudioSampleBuffer>.fromOpaque(storage)
                buffer.takeUnretainedValue().markStopped()
                buffer.release()
            },
            prepare: nil,
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    numberFrames,
                    bufferListInOut,
                    flagsOut,
                    nil,
                    numberFramesOut
                )
                guard status == noErr, let storage = MTAudioProcessingTapGetStorage(tap) else {
                    return
                }

                let buffer = Unmanaged<AudioSampleBuffer>.fromOpaque(storage)
                    .takeUnretainedValue()

                // One channel is enough for a spectrum, and mixing channels would be
                // arithmetic on a thread that must not do arithmetic it can avoid.
                let list = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                guard let first = list.first,
                      let data = first.mData
                else { return }

                let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                buffer.write(data.assumingMemoryBound(to: Float.self), count: count)
            }
        )

        var unmanagedTap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            // Post-effects, so this sees the samples on their way out rather than
            // before the player's own processing.
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &unmanagedTap
        )

        guard status == noErr, let tap = unmanagedTap else {
            // Balance the retain that will now never reach `finalize`.
            Unmanaged<AudioSampleBuffer>.fromOpaque(clientInfo).release()
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap.takeUnretainedValue()
        tap.release()

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
