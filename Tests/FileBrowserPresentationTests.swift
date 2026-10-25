import Foundation

extension FileOperationTests {
    static func fileBrowserPresentationTests() async {
        func item(_ name: String, kind: String = "文件", date: Date? = nil) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/presentation/\(name)"), name: name, typeDescription: kind,
                     isDirectory: false, isPackage: false, isAlias: false, aliasTargetURL: nil,
                     isAliasTargetDirectory: false, isAliasTargetPackage: false, isHidden: false,
                     size: 0, modifiedAt: date)
        }
        await test("presentation modes round trip and icon sizes remain bounded") { _ in
            for mode in FileBrowserViewMode.allCases {
                let restored = try JSONDecoder().decode(FileBrowserViewMode.self, from: JSONEncoder().encode(mode))
                try expect(restored == mode && !mode.title.isEmpty && !mode.systemImage.isEmpty, "mode lost")
            }
            for mode in FileGroupingMode.allCases {
                let restored = try JSONDecoder().decode(FileGroupingMode.self, from: JSONEncoder().encode(mode))
                try expect(restored == mode && !mode.title.isEmpty, "grouping lost")
            }
            for (input, output) in [(-1.0,48.0),(48,48),(96,96),(160,160),(900,160),(.nan,80),(.infinity,80)] {
                try expect(FileBrowserPresentation.clampedIconSize(input) == output, "invalid size \(input)")
            }
        }
        await test("presentation kind grouping uses natural order and preserves sorted group contents") { _ in
            let input = [item("b",kind:"Type 10"),item("c",kind:"Type 2"),item("a",kind:"Type 10")]
            let sections = FileBrowserPresentation.sections(from: input, grouping: .kind)
            try expect(sections.map(\.title) == ["Type 2","Type 10"], "not natural order")
            try expect(sections[1].items.map(\.name) == ["b","a"], "group reordered sort")
            try expect(sections.map(\.id) == FileBrowserPresentation.sections(from: input.reversed(), grouping: .kind).map(\.id), "unstable identity")
            let plain = FileBrowserPresentation.sections(from: input, grouping: .none)
            try expect(plain.count == 1 && plain[0].items == input, "none changed order")
            let empty = FileBrowserPresentation.sections(from: [], grouping: .kind)
            try expect(empty.isEmpty, "empty group exists")
        }
        await test("presentation date groups use civil day boundaries including daylight saving") { _ in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
            let today = calendar.startOfDay(for: now)
            func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
            // March 8 is 23 hours long. A fixed 24-hour subtraction would misclassify its first hour.
            let dates: [Date?] = [nil, day(-31),day(-30),day(-8),day(-7),day(-2),day(-1),today,now,now.addingTimeInterval(1)]
            let input = dates.enumerated().map { item("\($0.offset)",date:$0.element) }
            let sections = FileBrowserPresentation.sections(from: input, grouping: .modifiedDate, now: now, calendar: calendar)
            try expect(sections.map(\.id) == ["future","today","yesterday","last7days","last30days","older","unknown"], "date ordering wrong")
            try expect(sections.map { $0.items.map(\.name) } == [["9"],["7","8"],["6"],["4","5"],["2","3"],["1"],["0"]], "boundary classification wrong")
            let autumn = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: autumn))!
            let fall = FileBrowserPresentation.sections(from: [item("fall",date:yesterday)], grouping:.modifiedDate, now:autumn, calendar:calendar)
            try expect(fall.first?.id == "yesterday", "25-hour day misclassified")
        }
        await test("presentation selection range follows flattened visible order across groups") { _ in
            let input = [item("a",kind:"Z"),item("b",kind:"A"),item("c",kind:"Z"),item("d",kind:"A")]
            let sections = FileBrowserPresentation.sections(from:input,grouping:.kind)
            let flat = FileBrowserPresentation.flattenedItems(in:sections)
            try expect(flat.map(\.name) == ["b","d","a","c"], "flatten does not match sections")
            try expect(FileBrowserPresentation.selectionRange(from:input[0].id,to:input[1].id,in:sections).map(\.name) == ["b","d","a"], "reverse range wrong")
            try expect(FileBrowserPresentation.selectionRange(from:input[0].id,to:URL(fileURLWithPath:"/missing"),in:sections).isEmpty,"missing anchor selected")
        }
        await test("presentation keyboard navigation respects rows sections and partial rows") { _ in
            func nav(_ index:Int?,_ direction:FileBrowserNavigationDirection,_ counts:[Int] = [5,2,4]) -> Int? {
                FileBrowserPresentation.navigationIndex(from:index,direction:direction,sectionCounts:counts,columns:3)
            }
            try expect(nav(2,.right) == 2 && nav(3,.left) == 3 && nav(4,.right) == 4, "horizontal wrapped")
            try expect(nav(2,.down) == 4 && nav(4,.down) == 6 && nav(6,.down) == 8, "partial row down wrong")
            try expect(nav(7,.up) == 5 && nav(6,.up) == 4 && nav(4,.up) == 1, "section up wrong")
            try expect(nav(0,.up) == 0 && nav(10,.down) == 10, "outer edge escaped")
            try expect(nav(nil,.down) == 0 && nav(-1,.up) == 0 && nav(20,.right) == 0, "invalid selection")
            try expect(nav(nil,.right,[]) == nil && nav(nil,.left,[0,-1]) == nil, "empty collection")
            try expect(FileBrowserPresentation.navigationIndex(from:1,direction:.down,itemCount:3,columns:0) == 2,"zero columns")
            try expect(nav(4,.down,[0,5,0,2]) == 6,"empty sections changed layout")
        }
        await test("presentation 10k grouping preserves every identity and input order within groups") { _ in
            let input = (0..<10_000).map { item("item\($0)",kind:"Type \($0 % 10)") }
            let started = Date()
            let sections = FileBrowserPresentation.sections(from:input,grouping:.kind)
            let flattened = FileBrowserPresentation.flattenedItems(in:sections)
            try expect(flattened.count == input.count && Set(flattened.map(\.id)).count == input.count,"lost or duplicate files")
            try expect(sections[3].items.map(\.id) == input.filter { $0.typeDescription == "Type 3" }.map(\.id),"order changed")
            try expect(Date().timeIntervalSince(started) < 5,"10k grouping exceeded generous 5s regression budget")
        }
    }
}
