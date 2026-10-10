import Foundation
import SwiftExtension
import Synchronization

let asyncCount = Atomic<Int32>(0)
let syncCount = Atomic<Int32>(0)
let bgDone = Atomic<Int32>(0)

/// 在主執行緒呼叫：排一個工作給 MainActor。
@_cdecl("vgp_async_on_main")
public func vgpAsyncOnMain() {
  asyncOnMain { asyncCount.add(1, ordering: .sequentiallyConsistent) }
}

/// 開一條背景執行緒去呼叫 mainSync；主佇列沒人排空的話，那條執行緒會卡住、bgDone 維持 0。
@_cdecl("vgp_main_sync_from_bg")
public func vgpMainSyncFromBackground() {
  Thread.detachNewThread {
    mainSync { syncCount.add(1, ordering: .sequentiallyConsistent) }
    bgDone.store(1, ordering: .sequentiallyConsistent)
  }
}

@_cdecl("vgp_async_count")
public func vgpAsyncCount() -> Int32 { asyncCount.load(ordering: .sequentiallyConsistent) }

@_cdecl("vgp_sync_count")
public func vgpSyncCount() -> Int32 { syncCount.load(ordering: .sequentiallyConsistent) }

@_cdecl("vgp_bg_done")
public func vgpBackgroundDone() -> Int32 { bgDone.load(ordering: .sequentiallyConsistent) }

@_cdecl("vgp_is_main_thread")
public func vgpIsMainThread() -> Int32 { Thread.isMainThread ? 1 : 0 }

/// 2b 的 A' 做法：由宿主迴圈定期呼叫，讓 RunLoop 轉一圈、不等待。
@_cdecl("vgp_pump")
public func vgpPump() {
  _ = RunLoop.main.run(mode: .default, before: Date())
}
