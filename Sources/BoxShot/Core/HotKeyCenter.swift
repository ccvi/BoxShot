import AppKit
import Carbon.HIToolbox

// ============================================================
// 全局热键（Carbon RegisterEventHotKey）—— 沿用家族 HotKeyCenter 实现
//
// 注册 API 是"整批替换"形状（replaceAll(with:)）：早期版本 register()
// 内部先 unregisterAll()，注册第二个键时把第一个清掉，热键静默失效。
// 这个接口形状让那类 bug 写不出来，别改回去。
// ============================================================

final class HotKeyCenter {

    /// 四字符签名 'BSHT'（BoxShot），同签名 + 同 id 会撞车
    private static let signature: OSType = 0x4253_4854

    static let shared = HotKeyCenter()

    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef?, action: @MainActor () -> Void)] = [:]
    private var nextID: UInt32 = 1

    private init() {
        installHandler()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.fire(id: hotKeyID.id)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1,
                            &eventType,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
    }

    private func fire(id: UInt32) {
        guard let action = registrations[id]?.action else { return }
        MainActor.assumeIsolated { action() }
    }

    /// 整批替换全部全局键，返回注册失败的键位
    @discardableResult
    func replaceAll(with entries: [(spec: KeySpec, action: @MainActor () -> Void)]) -> [KeySpec] {
        unregisterAll()
        var failed: [KeySpec] = []
        for entry in entries {
            guard entry.spec.isUsableAsGlobal else {
                failed.append(entry.spec)
                continue
            }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(UInt32(entry.spec.keyCode),
                                             entry.spec.carbonModifiers,
                                             hotKeyID,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if status == noErr, let ref {
                registrations[id] = (ref, entry.action)
            } else {
                failed.append(entry.spec)
            }
        }
        return failed
    }

    func unregisterAll() {
        for (_, entry) in registrations {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
        }
        registrations.removeAll()
        nextID = 1
    }
}
