import Foundation
import AVFoundation
let original = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let composition = AVMutableComposition()
let video = original.tracks(withMediaType: .video).first!
let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
try target.insertTimeRange(CMTimeRange(start: .zero, duration: original.duration), of: video, at: .zero)
target.preferredTransform = video.preferredTransform
let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
export.outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
export.outputFileType = .mp4
let done = DispatchSemaphore(value: 0)
export.exportAsynchronously { done.signal() }
done.wait()
guard export.status == .completed else { fatalError(String(describing: export.error)) }
let result = AVURLAsset(url: export.outputURL!)
print("Duration:", result.duration.seconds, "video tracks:", result.tracks(withMediaType: .video).count, "audio tracks:", result.tracks(withMediaType: .audio).count)
