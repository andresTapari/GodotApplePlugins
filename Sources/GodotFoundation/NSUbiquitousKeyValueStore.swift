@preconcurrency import SwiftGodotRuntime
import Foundation
import CoreFoundation

private typealias NativeKeyValueStore = Foundation.NSUbiquitousKeyValueStore

/// Each wrapper uses Apple's default store. Keep the wrapper while you need its signals.
@Godot
public class NSUbiquitousKeyValueStore: RefCounted, @unchecked Sendable {
    public enum ChangeReason: Int, CaseIterable {
        case SERVER_CHANGE = 0
        case INITIAL_SYNC_CHANGE = 1
        case QUOTA_VIOLATION_CHANGE = 2
        case ACCOUNT_CHANGE = 3
    }

    @Signal("reason", "changed_keys")
    var did_change_externally: SignalWithArguments<Int, PackedStringArray>

    private let store = NativeKeyValueStore.default
    private var observer: (any NSObjectProtocol)?

    required public init(_ context: InitContext) {
        super.init(context)
        observer = NotificationCenter.default.addObserver(
            forName: NativeKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: nil
        ) { [weak self] notification in
            guard let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
                return
            }
            // Account and quota notifications can omit the changed keys.
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hasConnections(signal: "did_change_externally") else { return }
                self.did_change_externally.emit(reason, PackedStringArray(keys))
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @Callable
    static func default_store() -> NSUbiquitousKeyValueStore {
        NSUbiquitousKeyValueStore()
    }

    @Export var dictionaryRepresentation: VariantDictionary {
        Self.dictionaryToGodot(store.dictionaryRepresentation)
    }

    @Callable func synchronize() -> Bool { store.synchronize() }

    @Callable func object_for_key(key: String) -> Variant? {
        guard let value = store.object(forKey: key) else { return nil }
        return Self.toGodot(value)
    }

    @Callable func bool_for_key(key: String) -> Bool { store.bool(forKey: key) }
    @Callable func double_for_key(key: String) -> Double { store.double(forKey: key) }
    @Callable func long_long_for_key(key: String) -> Int64 { store.longLong(forKey: key) }
    @Callable func string_for_key(key: String) -> String { store.string(forKey: key) ?? "" }

    @Callable func data_for_key(key: String) -> PackedByteArray {
        PackedByteArray(Array(store.data(forKey: key) ?? Data()))
    }

    @Callable func array_for_key(key: String) -> VariantArray {
        Self.arrayToGodot(store.array(forKey: key) ?? [])
    }

    @Callable func dictionary_for_key(key: String) -> VariantDictionary {
        Self.dictionaryToGodot(store.dictionary(forKey: key) ?? [:])
    }

    @Callable func set_bool(value: Bool, key: String) -> Bool {
        guard validKey(key) else { return false }
        store.set(value, forKey: key)
        return true
    }

    @Callable func set_double(value: Double, key: String) -> Bool {
        guard validKey(key) else { return false }
        store.set(value, forKey: key)
        return true
    }

    @Callable func set_long_long(value: Int64, key: String) -> Bool {
        guard validKey(key) else { return false }
        store.set(value, forKey: key)
        return true
    }

    @Callable func set_string(value: String, key: String) -> Bool {
        guard validKey(key) else { return false }
        store.set(value, forKey: key)
        return true
    }

    @Callable func set_data(value: PackedByteArray, key: String) -> Bool {
        guard validKey(key) else { return false }
        store.set(Data(Array(value)), forKey: key)
        return true
    }

    @Callable func set_array(value: VariantArray, key: String) -> Bool {
        set_object(value: Variant(value), key: key)
    }

    @Callable func set_dictionary(value: VariantDictionary, key: String) -> Bool {
        set_object(value: Variant(value), key: key)
    }

    @Callable func set_object(value: Variant?, key: String) -> Bool {
        guard validKey(key) else { return false }
        guard let value, value.gtype != .nil else {
            store.removeObject(forKey: key)
            return true
        }
        guard let converted = Self.toFoundation(value) else {
            GD.pushError("The value must contain supported property list types. Containers must have at most 64 levels.")
            return false
        }
        store.set(converted, forKey: key)
        return true
    }

    @Callable func remove_object_for_key(key: String) {
        guard validKey(key) else { return }
        store.removeObject(forKey: key)
    }

    private func validKey(_ key: String) -> Bool {
        guard key.utf16.count <= 128 else {
            GD.pushError("The iCloud key must have at most 128 UTF-16 code units.")
            return false
        }
        return true
    }

    private static func toFoundation(_ value: Variant?, depth: Int = 0) -> Any? {
        guard let value, depth <= 64 else { return nil }
        switch value.gtype {
        case .bool: return Bool(value)
        case .int: return Int64(value)
        case .float: return Double(value)
        case .string: return String(value)
        case .packedByteArray:
            guard let bytes = PackedByteArray(value) else { return nil }
            return Data(Array(bytes))
        case .array:
            guard depth < 64, let array = VariantArray(value) else { return nil }
            var result: [Any] = []
            for element in array {
                guard let converted = toFoundation(element, depth: depth + 1) else { return nil }
                result.append(converted)
            }
            return result
        case .dictionary:
            guard depth < 64, let dictionary = VariantDictionary(value) else { return nil }
            var result: [String: Any] = [:]
            for key in dictionary.keys() {
                guard let key, key.gtype == .string, let name = String(key),
                      let converted = toFoundation(dictionary[key], depth: depth + 1) else { return nil }
                result[name] = converted
            }
            return result
        default: return nil
        }
    }

    private static func toGodot(_ value: Any) -> Variant? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return Variant(number.boolValue)
            }
            switch String(cString: number.objCType) {
            case "f", "d": return Variant(number.doubleValue)
            default: return Variant(number.int64Value)
            }
        case let string as String: return Variant(string)
        case let data as Data: return Variant(PackedByteArray(Array(data)))
        case let date as Date: return Variant(date.timeIntervalSince1970)
        case let array as [Any]: return Variant(arrayToGodot(array))
        case let dictionary as [String: Any]: return Variant(dictionaryToGodot(dictionary))
        default: return nil
        }
    }

    private static func arrayToGodot(_ values: [Any]) -> VariantArray {
        let result = VariantArray()
        for value in values {
            result.append(toGodot(value))
        }
        return result
    }

    private static func dictionaryToGodot(_ values: [String: Any]) -> VariantDictionary {
        let result = VariantDictionary()
        for (key, value) in values {
            result[key] = toGodot(value)
        }
        return result
    }
}
