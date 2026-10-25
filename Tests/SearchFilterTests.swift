import Foundation

extension FileOperationTests {
    static func searchFilterTests() async {
        func item(_ name: String = "report.TxT", directory: Bool = false, package: Bool = false,
                  network: Bool = false, size: Int64? = 100, created: Date? = nil, modified: Date? = nil) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/filters/\(name)"), name: name, typeDescription: "",
                     isDirectory: directory, isPackage: package, isAlias: false, aliasTargetURL: nil,
                     isAliasTargetDirectory: false, isAliasTargetPackage: false, isHidden: false,
                     size: size, modifiedAt: modified, createdAt: created, isNetworkLocation: network)
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { return }
            throw TestFailure.assertion("invalid filter was accepted")
        }
        await test("search filters default accepts missing metadata and remains inactive") { _ in
            let filters = SearchFilters()
            try filters.validate()
            try expect(!filters.isActive && filters.matches(item(size: nil)), "default filtered a file")
            try expect(filters.matches(item(directory: true, package: true)), "default filtered a package")
            let candidate = item(size: nil)
            let value = await Task.detached { SearchFilters().matches(candidate) }.value
            try expect(value, "not callable outside main actor")
        }
        await test("search filters kinds distinguish files folders packages and network") { _ in
            let fixtures = [item(), item(directory: true), item("Test.app", directory: true, package: true), item(network: true)]
            for (kind, expected) in [(SearchFilters.Kind.any, [true,true,true,true]), (.files,[true,false,false,false]),
                                     (.folders,[false,true,false,false]), (.packages,[false,false,true,false])] {
                let filters = SearchFilters(kind: kind)
                try expect(fixtures.map(filters.matches) == expected, "kind \(kind) is wrong")
                try expect(filters.isActive == (kind != .any), "kind activity wrong")
            }
        }
        await test("search filters extensions normalize OR unicode and reject path input") { _ in
            let parsed = try SearchFilters.parseExtensions(" .TXT, jpg,TXT, .数据, , ")
            try expect(parsed == ["txt","jpg","数据"], "extension normalization failed")
            let filters = SearchFilters(extensions: [" .TxT ", ".JPG", "数据", "é"])
            try filters.validate()
            for name in ["report.txt","photo.JPG","名字.数据","accent.e\u{301}"] {
                try expect(filters.matches(item(name)), "valid suffix rejected: \(name)")
            }
            try expect(!filters.matches(item("report.pdf")) && !filters.matches(item("README")), "unmatched suffix accepted")
            let empty = try SearchFilters.parseExtensions(" , ")
            try expect(empty.isEmpty, "blank parse not empty")
            for invalid in [".","x/y","x\\y","a\0b", " "] {
                try rejects { try SearchFilters(extensions: [invalid]).validate() }
                try expect(!SearchFilters(extensions: [invalid]).matches(item()), "invalid filter failed open")
            }
        }
        await test("search filters size bounds inclusive and unknown sizes excluded") { _ in
            let filters = SearchFilters(minimumSize: 100, maximumSize: 100)
            try filters.validate()
            try expect(filters.matches(item()), "inclusive equal bounds rejected")
            for candidate in [item(size: 99),item(size: 101),item(size: nil),item(size: -1),
                              item(directory: true),item(directory: true,package: true),item(network: true)] {
                try expect(!filters.matches(candidate), "non-file size or out-of-range accepted")
            }
            try expect(SearchFilters(maximumSize: 0).matches(item(size: 0)), "empty file rejected")
            try expect(SearchFilters(minimumSize: Int64.max).matches(item(size: Int64.max)), "Int64 limit rejected")
            for invalid in [SearchFilters(minimumSize: -1), SearchFilters(maximumSize: -1), SearchFilters(minimumSize: 2,maximumSize: 1)] {
                try rejects { try invalid.validate() }
            }
        }
        await test("search filters date intervals are half open and require metadata") { _ in
            let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 200)
            let filters = SearchFilters(createdAfterInclusive: start, createdBeforeExclusive: end,
                                        modifiedAfterInclusive: start, modifiedBeforeExclusive: end)
            try expect(filters.matches(item(created: start, modified: start)), "lower boundary excluded")
            try expect(filters.matches(item(created: end.addingTimeInterval(-0.001),modified: start)), "interior excluded")
            for candidate in [item(created: end,modified: start), item(created: start,modified: end),
                              item(created: start.addingTimeInterval(-1),modified: start),
                              item(created: nil,modified: start),item(created: start,modified: nil)] {
                try expect(!filters.matches(candidate), "date bounds or missing metadata accepted")
            }
            try expect(SearchFilters(createdAfterInclusive: start).matches(item(created: end)), "open upper bound failed")
            try expect(SearchFilters(modifiedBeforeExclusive: end).matches(item(modified: start)), "open lower bound failed")
            for invalid in [SearchFilters(createdAfterInclusive: end,createdBeforeExclusive: start),
                            SearchFilters(modifiedAfterInclusive: start,modifiedBeforeExclusive: start)] {
                try rejects { try invalid.validate() }
            }
        }
        await test("search filters combine metadata predicates with AND") { _ in
            let date = Date(timeIntervalSince1970: 100)
            let filters = SearchFilters(kind: .files, extensions: ["txt","jpg"], minimumSize: 50, maximumSize: 100,
                                        createdAfterInclusive: date, modifiedBeforeExclusive: date.addingTimeInterval(1))
            try expect(filters.matches(item(created: date,modified: date)), "complete match failed")
            for candidate in [item("file.pdf",created: date,modified: date),item(size: 49,created: date,modified: date),
                              item(created: date.addingTimeInterval(-1),modified: date),
                              item(created: date,modified: date.addingTimeInterval(1)),
                              item(directory: true,created: date,modified: date)] {
                try expect(!filters.matches(candidate), "AND condition ignored")
            }
        }
        await test("search filters integer MiB parser handles blank zero and overflow") { _ in
            let blank = try SearchFilters.parseSizeMiB(" \n")
            try expect(blank == nil, "blank bound not nil")
            let two = try SearchFilters.parseSizeMiB(" 2 ")
            try expect(two == 2_097_152, "MiB conversion wrong")
            let zero = try SearchFilters.parseSizeMiB("0")
            try expect(zero == 0, "zero conversion wrong")
            let largest = Int64.max / 1_048_576
            let safe = try SearchFilters.parseSizeMiB(String(largest))
            try expect(safe == largest * 1_048_576, "largest safe value rejected")
            for input in ["-1","1.5","abc",String(largest + 1),String(Int64.max),"9223372036854775808"] {
                try rejects { _ = try SearchFilters.parseSizeMiB(input) }
            }
        }
    }
}
