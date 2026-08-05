import AudioLinkReporting
import Foundation

@main
struct AudioLinkReportTool {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let input = value(after: "--input", in: arguments),
                  let output = value(after: "--output", in: arguments),
                  let formatValue = value(after: "--format", in: arguments),
                  let format = ReportExportFormat(rawValue: formatValue) else {
                print("Usage: AudioLinkReportTool --input report.json --format json|csv|html|pdf|png --output PATH")
                return
            }
            let document = try JSONCodec.decode(Data(contentsOf: URL(fileURLWithPath: input)))
            let urls = try await ReportExporter.write(document: document, format: format, to: URL(fileURLWithPath: output))
            urls.forEach { print($0.path) }
        } catch {
            fputs("AudioLinkReportTool: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(arguments.index(after: index)) else { return nil }
        return arguments[arguments.index(after: index)]
    }
}
