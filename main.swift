// ColorSwap — печать, когда закончился чёрный картридж.
//
// Каждая страница PDF рендерится в оттенки серого, а потом серый перекрашивается
// в цвет, который принтер собирает БЕЗ чёрных чернил. Чтобы драйвер не взял
// чёрный, у цвета один RGB-канал должен быть равен 255: чёрная составляющая
// K = 1 − max(R,G,B) тогда равна нулю. Самые тёмные такие цвета — смеси двух
// цветных чернил: синий (C+M), красный (M+Y), зелёный (C+Y).
//
// Цвет меняется от документа к документу: каждый картридж входит ровно в два цвета
// из трёх, а следующий цвет выбирается так, чтобы разгрузить самый потраченный
// картридж (учитывается реальная заливка напечатанных страниц).
//
// Тексты интерфейса — в Resources/*.lproj (en, de, ru, fr, es); ключи — английский текст.
//
// Запуск:
//   • из диалога печати: PDF ▾ → «Печать без чёрного» / «Print without Black»
//   • перетащить PDF на иконку приложения
//   • ColorSwap --convert in.pdf out.pdf [blue|red|green]   (без интерфейса, расход не учитывает)
//   • ColorSwap --stats                                      (сколько потрачено каждого цвета)

import AppKit
import PDFKit

/// Локализованная строка (ключ — английский текст) с подстановкой аргументов.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

// MARK: - Настройки

struct Ink {
    let id: String
    let r, g, b: Double
    var name: String { L(id) }
    /// Доля голубых, пурпурных и жёлтых чернил в этом цвете.
    var cmy: [Double] { [1 - r, 1 - g, 1 - b] }
}

/// Цвета вместо чёрного. У каждого один канал = 1, иначе драйвер возьмёт чёрный.
let inks = [
    Ink(id: "blue",  r: 0, g: 0, b: 1),  // голубой + пурпурный
    Ink(id: "red",   r: 1, g: 0, b: 0),  // пурпурный + жёлтый
    Ink(id: "green", r: 0, g: 1, b: 0),  // голубой + жёлтый
]
/// > 1 делает полутона и тонкий текст плотнее (больше чернил), < 1 светлее.
let contrastGamma = 1.5
/// Разрешение растра, точек на дюйм.
let dpi: CGFloat = 400

// MARK: - Учёт расхода

enum InkStats {
    static let keys = ["usedC", "usedM", "usedY"]
    static var defaults: UserDefaults { .standard }
    /// Потрачено голубого, пурпурного, жёлтого — в «страницах сплошной заливки».
    static var used: [Double] { keys.map { defaults.double(forKey: $0) } }
    static var last: Ink? { inks.first { $0.id == defaults.string(forKey: "lastInk") } }

    /// Не повторяем прошлый цвет и берём тот, что меньше нагружает уже потраченные картриджи.
    static func pick() -> Ink {
        let u = used
        let options = inks.filter { $0.id != last?.id }
        func load(_ ink: Ink) -> Double { zip(u, ink.cmy).reduce(0) { $0 + $1.0 * $1.1 } }
        let best = options.map(load).min()!
        return options.filter { load($0) <= best + 0.01 }.randomElement()!
    }

    static func record(_ ink: Ink, coverage: Double) {
        for (key, (was, part)) in zip(keys, zip(used, ink.cmy)) {
            defaults.set(was + coverage * part, forKey: key)
        }
        defaults.set(ink.id, forKey: "lastInk")
    }
}

// MARK: - Конвертер

struct ConvertError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Насколько светлым остаётся серый g (0…255) после повышения контраста: 0 — полные чернила, 1 — бумага.
func lightness(_ g: Int) -> Double {
    let l = Double(g) / 255
    return l >= 0.98 ? 1 : pow(l, contrastGamma)  // почти белое оставляем белым, без лишних чернил
}

/// Палитра 256 оттенков: серый g → смесь цвета и белой бумаги.
func makePalette(_ ink: Ink) -> [UInt8] {
    var table: [UInt8] = []
    for g in 0...255 {
        let l = lightness(g)
        for c in [ink.r, ink.g, ink.b] {
            table.append(UInt8((255 * (c + (1 - c) * l)).rounded()))
        }
    }
    return table
}

/// Перекрашивает PDF. Возвращает заливку в «страницах сплошной заливки», для учёта расхода.
@discardableResult
func convert(_ src: URL, to dst: URL, ink: Ink) throws -> Double {
    guard let doc = CGPDFDocument(src as CFURL), doc.numberOfPages > 0 else {
        throw ConvertError(L("Could not open the PDF: %@", src.lastPathComponent))
    }
    if doc.isEncrypted && !doc.unlockWithPassword("") {
        throw ConvertError(L("The PDF is password-protected."))
    }
    guard let out = CGContext(dst as CFURL, mediaBox: nil, nil) else {
        throw ConvertError(L("Could not create %@", dst.path))
    }
    let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
    let indexed = CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               last: 255, colorTable: makePalette(ink))!
    var coverage = 0.0

    for i in 1...doc.numberOfPages {
        guard let page = doc.page(at: i) else { continue }
        let box = page.getBoxRect(.cropBox)
        let size = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let w = Int((size.width * dpi / 72).rounded()), h = Int((size.height * dpi / 72).rounded())

        // 1. Страница → 8-битный серый растр.
        guard let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ConvertError(L("Not enough memory for page %d.", i))
        }
        bmp.setFillColor(gray: 1, alpha: 1)
        bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bmp.interpolationQuality = .high
        bmp.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        bmp.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        bmp.drawPDFPage(page)

        // 2. Сколько чернил уйдёт на страницу.
        let px = bmp.data!.assumingMemoryBound(to: UInt8.self)
        var hist = [Int](repeating: 0, count: 256)
        for y in 0..<h {
            let row = px + y * bmp.bytesPerRow
            for x in 0..<w { hist[Int(row[x])] += 1 }
        }
        coverage += (0...255).reduce(0.0) { $0 + Double(hist[$1]) * (1 - lightness($1)) } / Double(w * h)

        // 3. Те же байты, но как индексированная картинка: палитра сама превращает серый в цвет.
        let bytes = Data(bytes: px, count: bmp.bytesPerRow * h)
        guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: bmp.bytesPerRow, space: indexed, bitmapInfo: [],
                                provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
            throw ConvertError(L("Could not prepare page %d.", i))
        }

        // 4. Новая страница того же размера.
        var media = CGRect(origin: .zero, size: size)
        out.beginPage(mediaBox: &media)
        out.draw(img, in: media)
        out.endPage()
    }
    out.closePDF()
    return coverage
}

// MARK: - Приложение

/// Название пункта в меню PDF ▾ — локализованное имя приложения.
var displayName: String {
    Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? "Print without Black"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var queue: [URL] = []
    private var busy = false
    private var gotFiles = false

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        gotFiles = true
        queue += filenames.map { URL(fileURLWithPath: $0) }
        sender.reply(toOpenOrPrint: .success)
        DispatchQueue.main.async { self.processQueue() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запустили двойным кликом, без файла — предложим выбрать PDF.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !self.gotFiles else { return }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.allowsMultipleSelection = true
            panel.message = L("Choose a PDF. Black will be printed with color ink.")
            panel.prompt = L("Print")
            guard panel.runModal() == .OK else { NSApp.terminate(nil); return }
            self.queue += panel.urls
            self.processQueue()
        }
    }

    private func processQueue() {
        guard !busy else { return }
        busy = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ColorSwap", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        while !queue.isEmpty {
            let src = queue.removeFirst()
            let title = src.deletingPathExtension().lastPathComponent
            let dst = tmp.appendingPathComponent(UUID().uuidString + ".pdf")
            let ink = InkStats.pick()
            do {
                let coverage = try convert(src, to: dst, ink: ink)
                // Расход считаем, только если документ действительно отправили на печать.
                if try printPDF(dst, title: "\(title) (\(ink.name))") {
                    InkStats.record(ink, coverage: coverage)
                }
            } catch {
                showError(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: dst)
        }
        busy = false
        NSApp.terminate(nil)
    }

    private func printPDF(_ url: URL, title: String) throws -> Bool {
        guard let doc = PDFDocument(url: url) else { throw ConvertError(L("Could not open the converted PDF.")) }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        // Если в прошлый раз печатали «Ч/Б», драйвер взял бы чёрный. Поэтому принудительно включаем цвет.
        info.printSettings["ColorModel"] = "RGB"
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            throw ConvertError(L("Could not start printing."))
        }
        op.jobTitle = title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        NSApp.activate(ignoringOtherApps: true)
        return op.run()
    }

    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = displayName
        alert.informativeText = text
        alert.runModal()
    }
}

// MARK: - Точка входа

let args = CommandLine.arguments
if args.count >= 4 && args[1] == "--convert" {
    do {
        let ink = args.count > 4 && !args[4].hasPrefix("-") ? inks.first { $0.id == args[4] } : InkStats.pick()
        guard let ink else { throw ConvertError(L("Available colors: blue, red, green")) }
        let coverage = try convert(URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[3]), ink: ink)
        print(L("Color: %@, coverage: %.3f pages", ink.name, coverage))
    } catch {
        FileHandle.standardError.write(Data("ColorSwap: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}
if args.count >= 2 && args[1] == "--stats" {
    for (key, value) in zip(["cyan", "magenta", "yellow"], InkStats.used) {
        print(L("%@: %.3f pages of solid fill", L(key), value))
    }
    print(L("Last color: %@", InkStats.last?.name ?? "—"))
    exit(0)
}
if args.count >= 2 && args[1] == "--menu-name" {  // для install.sh
    print(displayName)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
