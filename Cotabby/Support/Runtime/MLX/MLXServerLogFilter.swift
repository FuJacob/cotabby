import Foundation

/// File overview:
/// Cleans `mlx_lm.server`'s stderr before it is quoted as a failure reason. The server is a Python
/// `http.server`, which prints one access line per request and a full traceback for every client
/// that disconnects early (Cotabby cancels a stream whenever the user types again). Left in, those
/// bury the one traceback that matters, such as `generation thread died`. Pure and stateless, so
/// it lives in `Support/` and is tested with a realistic transcript.
nonisolated enum MLXServerLogFilter {
    /// The last `limit` lines of `lines` once access-log lines and disconnect tracebacks are gone.
    static func relevantTail(_ lines: [String], limit: Int) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isAccessLine(line) {
                index += 1
            } else if line.hasPrefix("Traceback (most recent call last)") {
                let end = tracebackEnd(in: lines, from: index)
                let block = Array(lines[index...end])
                if isDisconnect(block) {
                    // http.server frames the traceback with a dashed rule and an "Exception occurred"
                    // line before it and a dashed rule after it. Drop those with the block.
                    while let last = kept.last, isDashRule(last) || last.hasPrefix("Exception occurred during processing") {
                        kept.removeLast()
                    }
                    index = end + 1
                    if index < lines.count, isDashRule(lines[index]) { index += 1 }
                } else {
                    kept.append(contentsOf: block)
                    index = end + 1
                }
            } else {
                kept.append(line)
                index += 1
            }
        }
        return Array(kept.suffix(limit))
    }

    /// `127.0.0.1 - - [date] "POST /v1/completions HTTP/1.1" 200 -`
    private static func isAccessLine(_ line: String) -> Bool {
        line.range(of: #""[A-Z]+ \S+ HTTP/\d(\.\d)?" \d{3}"#, options: .regularExpression) != nil
    }

    private static func isDashRule(_ line: String) -> Bool {
        line.count >= 10 && line.allSatisfy { $0 == "-" }
    }

    /// Index of the traceback's last line: its exception line, or further when the exception was
    /// chained ("During handling of the above exception..."). A traceback still being written ends
    /// at the last line available.
    private static func tracebackEnd(in lines: [String], from start: Int) -> Int {
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            let isFrame = line.hasPrefix(" ") || line.hasPrefix("\t")
            if !isFrame {
                // The exception line closes the block unless another traceback chains onto it.
                let next = index + 1 < lines.count ? lines[index + 1] : nil
                if let next, next.hasPrefix("During handling") || next.hasPrefix("The above exception") {
                    index += 2
                    continue
                }
                if line.hasPrefix("During handling") || line.hasPrefix("The above exception")
                    || line.hasPrefix("Traceback (most recent call last)") {
                    index += 1
                    continue
                }
                return index
            }
            index += 1
        }
        return lines.count - 1
    }

    private static func isDisconnect(_ block: [String]) -> Bool {
        block.contains { $0.hasPrefix("BrokenPipeError") || $0.hasPrefix("ConnectionResetError")
            || $0.hasPrefix("ConnectionAbortedError") }
    }
}
