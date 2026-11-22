import Foundation

/// H.264 影像封包格式：
/// [1 byte flags][1 byte 參數集數量 n]{[2 bytes 長度][SPS/PPS]} × n [AVCC 資料（4-byte 長度前綴 NAL）]
struct VideoPacket {
    var isKeyframe: Bool
    var parameterSets: [Data]
    var payload: Data

    func serialized() -> Data {
        var data = Data()
        data.append(isKeyframe ? 1 : 0)
        data.append(UInt8(parameterSets.count))
        for set in parameterSets {
            let len = UInt16(set.count)
            data.append(UInt8(len >> 8))
            data.append(UInt8(len & 0xFF))
            data.append(set)
        }
        data.append(payload)
        return data
    }

    init(isKeyframe: Bool, parameterSets: [Data], payload: Data) {
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
        self.payload = payload
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        isKeyframe = bytes[0] & 1 == 1
        let count = Int(bytes[1])
        var offset = 2
        var sets: [Data] = []
        for _ in 0..<count {
            guard offset + 2 <= bytes.count else { return nil }
            let len = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard offset + len <= bytes.count else { return nil }
            sets.append(Data(bytes[offset..<offset + len]))
            offset += len
        }
        parameterSets = sets
        payload = Data(bytes[offset...])
    }
}
