import Foundation

/// `PrefSnapSnapshot` を Git 差分管理しやすい整形済み・キーソート済み JSON へ変換するシリアライザ。
public struct SnapshotSerializer: Sendable {
    public init() {}

    /// スナップショットを Pretty-printed かつキーソート済み JSON データへエンコードする。
    public func encode(_ snapshot: PrefSnapSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(snapshot)
            // Git での差分管理をしやすくするため末尾に改行を付与する
            if data.last != 0x0A {
                data.append(0x0A)
            }
            return data
        } catch {
            throw PrefSnapError.serializationFailed(detail: error.localizedDescription)
        }
    }

    /// JSON データから `PrefSnapSnapshot` をデコードし、`schemaVersion` の互換性を検証する。
    public func decode(_ data: Data) throws -> PrefSnapSnapshot {
        let decoder = JSONDecoder()
        let snapshot: PrefSnapSnapshot
        do {
            snapshot = try decoder.decode(PrefSnapSnapshot.self, from: data)
        } catch {
            throw PrefSnapError.serializationFailed(detail: error.localizedDescription)
        }

        guard snapshot.schemaVersion == PrefSnapSnapshot.currentSchemaVersion else {
            throw PrefSnapError.unsupportedSchemaVersion(
                found: snapshot.schemaVersion,
                supported: PrefSnapSnapshot.currentSchemaVersion
            )
        }
        return snapshot
    }
}
