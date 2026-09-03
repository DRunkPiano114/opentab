// Generator for Sources/OpenTabCore/Pinyin/PinyinTable.swift.
//
//   swift Scripts/gen-pinyin-table.swift \
//     > Packages/OpenTabKit/Sources/OpenTabCore/Pinyin/PinyinTable.swift
//
// Readings come from Foundation's ICU transliterator: "Han-Latin" for the
// primary reading and "Han-Latin/Names" for the reading ICU prefers in names,
// which is often a second common pronunciation. ICU gives one reading per
// transform, so polyphones whose alternates matter for search are listed in
// `curatedPolyphones` below and take priority over ICU's order. Diagnostics go
// to stderr; only the Swift source goes to stdout.

import Foundation

// MARK: - Curated polyphones

// One character per line followed by its toneless readings, most common first.
// These are the readings a user might type when searching for a window title,
// so an alternate that is merely rare costs a rare false hit while a missing
// one loses the match: prefer recall. Readings that survive only in classical
// texts are left out. Write "ü" where the syllable has one; both the "v" and
// the "u" spelling are derived from it.
let curatedSource = """
重 zhong chong
长 chang zhang
行 xing hang
乐 le yue
还 hai huan
都 dou du
得 de dei
着 zhe zhao zhuo
会 hui kuai
传 chuan zhuan
差 cha chai ci
曾 ceng zeng
藏 cang zang
处 chu
调 diao tiao
血 xue xie
朝 chao zhao
参 can shen cen
省 sheng xing
解 jie xie
单 dan shan chan
校 xiao jiao
卡 ka qia
系 xi ji
强 qiang jiang
折 zhe she
弹 dan tan
相 xiang
少 shao
数 shu
发 fa
干 gan
中 zhong
好 hao
分 fen
种 zhong
兴 xing
应 ying
更 geng
假 jia
空 kong
恶 e wu
觉 jue jiao
露 lu lou
薄 bao bo
泊 bo po
塞 sai se
便 bian pian
熟 shu shou
给 gei ji
累 lei
量 liang
吓 xia he
度 du duo
落 luo la lao
没 mei mo
模 mo mu
似 si shi
说 shuo shui
秘 mi bi
圈 quan juan
色 se shai
厦 sha xia
什 shen shi
识 shi zhi
率 lü shuai
涨 zhang
只 zhi
仔 zai zi
扎 zha za
粘 zhan nian
区 qu ou
龟 gui jun
乘 cheng sheng
剥 bao bo
查 cha zha
仇 chou qiu
朴 pu piao
翟 zhai di
奇 qi ji
宿 su xiu
削 xiao xue
缝 feng
挑 tiao
号 hao
当 dang
尽 jin
教 jiao
拧 ning
撒 sa
扫 sao
舍 she
铺 pu
磨 mo
冠 guan
供 gong
观 guan
华 hua
几 ji
荷 he
结 jie
禁 jin
卷 juan
咳 ke hai
蒙 meng
难 nan
排 pai
切 qie
任 ren
散 san
属 shu zhu
汤 tang shang
症 zheng
占 zhan
曲 qu
载 zai
转 zhuan
提 ti di
盛 sheng cheng
弄 nong long
拾 shi she
丧 sang
骑 qi
铅 qian yan
燕 yan
叶 ye xie
尉 wei yu
万 wan mo
阿 a e
啊 a
吗 ma
呢 ne ni
哪 na nei
那 na nei
谁 shui shei
和 he huo hu
大 da dai
地 di de
了 le liao
为 wei
与 yu
于 yu
的 de di
不 bu fou
儿 er
亲 qin qing
冲 chong
创 chuang
扁 bian pian
番 fan pan
佛 fo fu
哈 ha
巷 xiang hang
壳 ke qiao
蔓 man wan
匙 chi shi
尺 chi che
臭 chou xiu
逮 dai
石 shi dan
芒 mang
沓 ta da
拓 tuo ta
伎 ji
悄 qiao
场 chang
厂 chang
期 qi ji
惬 qie
龙 long
弱 ruo
宁 ning
咽 yan ye
殷 yin yan
疟 nüe yao
缪 miu mou miao
苔 tai
柏 bai bo
蕃 fan bo
沈 shen chen
盖 gai ge
葛 ge
过 guo
纪 ji
靓 liang jing
乜 mie nie
佟 tong
阚 kan
拗 ao niu
扒 ba pa
扳 ban pan
磅 bang pang
堡 bao pu bu
背 bei
奔 ben
辟 pi bi
臂 bi bei
屏 ping bing
伯 bo bai
簸 bo
卜 bu bo
禅 chan shan
颤 chan zhan
称 cheng chen
澄 cheng deng
车 che ju
畜 chu xu
揣 chuai
绰 chuo chao
攒 zan cuan
撮 cuo zuo
答 da
打 da
担 dan
倒 dao
钉 ding
读 du dou
囤 tun dun
诶 ei
坊 fang
否 fou pi
夫 fu
服 fu
脯 fu pu
杆 gan
杠 gang
革 ge ji
蛤 ge ha
颈 jing geng
勾 gou
估 gu
骨 gu
鹄 hu gu
桧 gui hui
虾 xia ha
汗 han
喝 he
横 heng
哄 hong
糊 hu
划 hua
化 hua
坏 huai
豁 huo huai
混 hun
稽 ji qi
夹 jia ga
间 jian
将 jiang
角 jiao jue
脚 jiao jue
嚼 jiao jue
酵 jiao xiao
芥 jie gai
矜 jin qin
劲 jin jing
咀 ju zui
句 ju gou
菌 jun
看 kan
坷 ke
框 kuang
括 kuo
拉 la
喇 la
烙 lao luo
勒 le lei
擂 lei
肋 lei le
棱 leng ling
撩 liao
咧 lie
淋 lin
令 ling
溜 liu
碌 lu liu
搂 lou
绿 lü
论 lun
抡 lun
啰 luo
麻 ma
埋 mai man
脉 mai mo
氓 mang meng
么 me yao
闷 men
弥 mi
泌 mi bi
靡 mi
摩 mo
抹 mo ma
牟 mou mu
淖 nao zhuo
虐 nüe
哦 o e
派 pai pa
胖 pang pan
刨 pao bao
炮 pao bao
喷 pen
劈 pi
片 pian
漂 piao
撇 pie
仆 pu
栖 qi xi
契 qi xie
浅 qian jian
嵌 qian kan
呛 qiang
且 qie ju
雀 que qiao
绕 rao
喏 nuo re
啥 sha
杉 shan sha
苕 shao tiao
莘 shen xin
甚 shen shi
遂 sui
台 tai
趟 tang
帖 tie
同 tong
凸 tu
吐 tu
屯 tun
瓦 wa
王 wang
往 wang
尾 wei yi
委 wei
挝 wo zhua
乌 wu
无 wu mo
洗 xi xian
纤 xian qian
鲜 xian
挟 xie jia
旋 xuan
穴 xue
熏 xun
压 ya
崖 ya
哑 ya
研 yan
仰 yang
药 yao
要 yao
钥 yao yue
一 yi
遗 yi wei
哟 yo
佣 yong
有 you
熨 yun yu
晕 yun
轧 ya zha ga
炸 zha
咋 za ze zha
召 zhao shao
爪 zhua zhao
这 zhe
殖 zhi
轴 zhou
术 shu zhu
刷 shua
幢 zhuang chuang
综 zong zeng
钻 zuan
作 zuo
繁 fan po
郗 xi chi
逄 pang
隗 kui wei
钭 tou
洞 dong
挨 ai
噎 ye
咯 ge lo ka
唉 ai
呗 bei
啐 cui
嗲 dia
哼 heng
呸 pei
唔 wu ng
嗯 en ng
呣 m mu
锁 suo
茄 qie jia
藉 jie ji
薯 shu
柚 you
莎 sha suo
菲 fei
苇 wei
荸 bi
葩 pa
蓿 xu
苜 mu
枸 gou ju
桔 ju jie
栎 li yue
槟 bin bing
榧 fei
橇 qiao
檀 tan
氽 tun
汆 cuan
潜 qian
澹 dan tan
瀑 pu bao
炔 que
焙 bei
熬 ao
燎 liao
爆 bao
猬 wei
獐 zhang
玛 ma
琵 pi
瑟 se
璇 xuan
瓤 rang
甥 sheng
畈 fan
疙 ge
瘸 que
癖 pi
皑 ai
盹 dun
瞅 chou
矮 ai
砚 yan
碾 nian
磷 lin
祢 mi ni
禽 qin
稗 bai
穗 sui
窖 jiao
竺 zhu du
筏 fa
簿 bu
粳 jing geng
糜 mi mei
纶 lun guan
绦 tao
缔 di
罄 qing
翘 qiao
耙 ba pa
聒 guo
肖 xiao
胖 pang pan
腌 yan a
膀 bang pang
臊 sao
舀 yao
艄 shao
芋 yu
苞 bao
茜 qian xi
荠 ji qi
莞 wan guan
菏 he
葚 shen ren
蓖 bi
薅 hao
藩 fan
虬 qiu
蚌 bang beng
蛔 hui
蜇 zhe
螨 man
衅 xin
袄 ao
裨 bi pi
褪 tui tun
觅 mi
訾 zi
谙 an
豚 tun
貉 he hao
贲 ben bi
赦 she
趔 lie
跷 qiao
踹 chuai
躅 zhu
辈 bei
迄 qi
逯 lu
遏 e
邂 xie
郾 yan
酌 zhuo
醴 li
釉 you
铄 shuo
锃 zeng
镌 juan
闰 run
阂 he
陂 bei pi po
隼 sun
雎 ju
霭 ai
靡 mi
鞅 yang
颓 tui
飙 biao
饽 bo
馥 fu
骁 xiao
髦 mao
魅 mei
鲍 bao
鹘 hu gu
麾 hui
黏 nian
鼾 han
龋 qu
"""

// MARK: - Reading normalisation

/// Combining tone marks ICU emits. The diaeresis U+0308 is deliberately kept:
/// it is the only way to tell "lüe" from "lue" once the tone is gone.
let toneMarks: Set<Unicode.Scalar> = ["\u{0300}", "\u{0301}", "\u{0304}", "\u{030C}", "\u{0306}", "\u{0302}"]

/// Toneless lowercase forms of one ICU reading. A syllable with "ü" yields two
/// spellings, "v" first, because IME users type "nv" far more often than "nu".
func normalise(_ raw: String) -> [String] {
    var stripped = String.UnicodeScalarView()
    for scalar in raw.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
    where !toneMarks.contains(scalar) {
        stripped.append(scalar)
    }
    let text = String(stripped).precomposedStringWithCanonicalMapping
    guard !text.isEmpty else { return [] }

    if text.contains("\u{00FC}") {
        let v = text.replacingOccurrences(of: "\u{00FC}", with: "v")
        let u = text.replacingOccurrences(of: "\u{00FC}", with: "u")
        return [v, u].filter(isASCIILetters)
    }
    return isASCIILetters(text) ? [text] : []
}

func isASCIILetters(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A }
}

func transliterate(_ scalar: Unicode.Scalar, _ transform: String) -> String? {
    let source = String(scalar)
    guard let out = source.applyingTransform(StringTransform(rawValue: transform), reverse: false),
          out != source, !out.contains(" ")
    else { return nil }
    return out
}

// MARK: - Build the reading table

var curated: [Unicode.Scalar: [String]] = [:]
var curatedOrder: [Unicode.Scalar] = []
for line in curatedSource.split(separator: "\n") {
    let fields = line.split(separator: " ")
    guard let head = fields.first, let scalar = head.unicodeScalars.first, fields.count > 1 else {
        FileHandle.standardError.write("malformed curated line: \(line)\n".data(using: .utf8)!)
        continue
    }
    if curated[scalar] == nil { curatedOrder.append(scalar) }
    var readings = curated[scalar] ?? []
    for field in fields.dropFirst() {
        for form in normalise(String(field)) where !readings.contains(form) {
            readings.append(form)
        }
    }
    curated[scalar] = readings
}

let rangeStart: UInt32 = 0x4E00
let rangeEnd: UInt32 = 0x9FFF

var readingsByIndex: [[String]] = []
var missingPrimary: [(Unicode.Scalar, String)] = []

for value in rangeStart...rangeEnd {
    let scalar = Unicode.Scalar(value)!
    var merged: [String] = []
    func add(_ forms: [String]) {
        for form in forms where !merged.contains(form) { merged.append(form) }
    }

    let curatedForms = curated[scalar]
    add(curatedForms ?? [])

    let primary = transliterate(scalar, "Han-Latin").map(normalise) ?? []
    if let curatedForms, let head = primary.first, !curatedForms.contains(head) {
        missingPrimary.append((scalar, head))
    }
    add(primary)
    add(transliterate(scalar, "Han-Latin/Names").map(normalise) ?? [])

    readingsByIndex.append(merged.filter { $0.count <= 6 })
}

// MARK: - Encode

// Every reading is one index into the syllable alphabet, written as two base-36
// digits; "-" ends a character's entry, so an unmapped character is a lone "-".
let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")

let syllables = Array(Set(readingsByIndex.flatMap { $0 })).sorted()
precondition(syllables.count <= digits.count * digits.count, "syllable alphabet overflows base-36 pairs")
var syllableIndex: [String: Int] = [:]
for (i, s) in syllables.enumerated() { syllableIndex[s] = i }

var blob = ""
blob.reserveCapacity(readingsByIndex.count * 4)
for readings in readingsByIndex {
    for reading in readings {
        let id = syllableIndex[reading]!
        blob.append(digits[id / 36])
        blob.append(digits[id % 36])
    }
    blob.append("-")
}

func literalLines(_ text: String, width: Int) -> String {
    var out: [String] = []
    var line = ""
    for ch in text {
        line.append(ch)
        if line.count >= width { out.append(line); line = "" }
    }
    if !line.isEmpty { out.append(line) }
    // A trailing backslash swallows the newline, so the literal is one
    // contiguous string and the parser needs no whitespace filtering.
    return out.map { "    \($0)\\" }.joined(separator: "\n")
}

let mappedCount = readingsByIndex.filter { !$0.isEmpty }.count
let readingCount = readingsByIndex.reduce(0) { $0 + $1.count }

// MARK: - Emit

var out = """
// Generated by Scripts/gen-pinyin-table.swift. Do not edit by hand.
//
// Readings come from Foundation's ICU transliterators "Han-Latin" and
// "Han-Latin/Names", merged with a curated polyphone list that lives in the
// generator. ICU exposes only one reading per transform, so the curated list
// supplies the alternates that matter for search (\u{91CD} zhong/chong) and fixes
// the order, most common first. Regenerate with:
//
//   swift Scripts/gen-pinyin-table.swift \\
//     > Packages/OpenTabKit/Sources/OpenTabCore/Pinyin/PinyinTable.swift
//
// Covers U+4E00...U+9FFF: \(mappedCount) characters, \(readingCount) readings,
// \(syllables.count) distinct syllables.

import Foundation

/// Han character to toneless pinyin, decoded once from a string literal.
///
/// The data is a literal rather than a bundled resource because OpenTabCore is
/// a static library linked straight into the app, where `Bundle.module` has no
/// resource bundle to find.
enum PinyinTable {
    static func readings(of scalar: Unicode.Scalar) -> [String] {
        guard scalar.value >= first, scalar.value <= last else { return [] }
        let table = decoded
        let index = Int(scalar.value - first)
        let start = Int(table.offsets[index])
        let end = Int(table.offsets[index + 1])
        guard start < end else { return [] }
        var result = [String]()
        result.reserveCapacity(end - start)
        for slot in start..<end {
            result.append(table.syllables[Int(table.ids[slot])])
        }
        return result
    }

    private static let first: UInt32 = 0x\(String(rangeStart, radix: 16, uppercase: true))
    private static let last: UInt32 = 0x\(String(rangeEnd, radix: 16, uppercase: true))

    /// Not private: the tests measure `decode()` on its own, because its cost
    /// lands on whichever lookup happens first at app startup.
    struct Decoded: Sendable {
        let syllables: [String]
        /// One more entry than there are characters; entry i spans
        /// `offsets[i]..<offsets[i + 1]` of `ids`.
        let offsets: [UInt32]
        let ids: [UInt16]
    }

    private static let decoded: Decoded = decode()

    static func decode() -> Decoded {
        let syllables = alphabet.split(separator: " ").map(String.init)
        let count = Int(last - first) + 1
        var offsets = [UInt32]()
        offsets.reserveCapacity(count + 1)
        var ids = [UInt16]()
        ids.reserveCapacity(count + count / 8)

        offsets.append(0)
        var high = -1
        for byte in entries.utf8 {
            if byte == UInt8(ascii: "-") {
                offsets.append(UInt32(ids.count))
                continue
            }
            let digit = byte <= UInt8(ascii: "9")
                ? Int(byte - UInt8(ascii: "0"))
                : Int(byte - UInt8(ascii: "a")) + 10
            if high < 0 {
                high = digit
            } else {
                ids.append(UInt16(high * 36 + digit))
                high = -1
            }
        }
        return Decoded(syllables: syllables, offsets: offsets, ids: ids)
    }

    /// Space-separated syllables in the order the entry indexes refer to.
    private static let alphabet = \"\"\"
\(literalLines(syllables.joined(separator: " "), width: 180))

    \"\"\"

    /// One entry per code point from `first`, each a run of two-base-36-digit
    /// syllable indexes terminated by "-".
    private static let entries = \"\"\"
\(literalLines(blob, width: 180))

    \"\"\"
}

"""

// The line-continuation form leaves one trailing backslash before the closing
// delimiter; drop it so the literal ends exactly at the last data character.
out = out.replacingOccurrences(of: "\\\n\n    \"\"\"", with: "\n    \"\"\"")

print(out, terminator: "")

// MARK: - Diagnostics

var log = ""
log += "distinct syllables: \(syllables.count)\n"
log += "mapped characters:  \(mappedCount) of \(readingsByIndex.count)\n"
log += "total readings:     \(readingCount)\n"
log += "entries blob bytes: \(blob.utf8.count)\n"
log += "alphabet bytes:     \(syllables.joined(separator: " ").utf8.count)\n"
log += "generated bytes:    \(out.utf8.count)\n"
log += "curated characters: \(curatedOrder.count)\n"
log += "curated readings missing ICU primary (\(missingPrimary.count)):\n"
for (scalar, primary) in missingPrimary {
    log += "  \(scalar) U+\(String(format: "%04X", scalar.value)) curated \(curated[scalar]!.joined(separator: ",")) + icu \(primary)\n"
}
FileHandle.standardError.write(log.data(using: .utf8)!)
