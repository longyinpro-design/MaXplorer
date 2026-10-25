import Darwin
import Foundation

extension FileOperationTests {
    static func filePropertyEditorTests() async {
        await test("property editor review freezes explicit nonrecursive permission and label changes") { dir in
            let parent = try directory(dir, "parent")
            let child = try file(parent, "child", "unchanged")
            let model = FilePropertyEditorModel()
            model.load([parent, child])
            while model.isLoading { await Task.yield() }
            try expect(model.entries.count == 2 && model.entries.allSatisfy { $0.snapshot != nil }, "original values missing")
            model.entries[0].editPermissions = true
            model.entries[0].permissions = "700"
            model.entries[1].editTags = true
            model.entries[1].tags = ["a,b", "中文"]
            model.prepareReview()
            try expect(model.review.count == 2, "explicit changes absent")
            model.entries[0].permissions = "777"
            model.entries[1].tags = ["changed after review"]
            await model.applyReviewed()
            try expect(model.results.count == 2 && model.results.allSatisfy { $0.error == nil }, "review apply failed")
            let actual = await FilePropertyService.inspect([parent, child])
            try expect(actual[0].snapshot?.permissions == 0o700 && actual[1].snapshot?.tagNames == ["a,b", "中文"], "mutable draft replaced reviewed values")
            try expect(contents(child) == "unchanged" && actual[1].snapshot?.permissions == 0o644, "recursive/other field change")
        }
        await test("property editor validates permissions and per-row labels before confirmation") { dir in
            let item = try file(dir, "file", "bytes")
            let model = FilePropertyEditorModel(); model.load([item])
            while model.isLoading { await Task.yield() }
            model.entries[0].editPermissions = true; model.entries[0].permissions = "888"
            model.prepareReview()
            try expect(model.review.isEmpty && model.error != nil, "invalid octal authorized")
            model.entries[0].permissions = "600"; model.entries[0].editTags = true
            for tags in [[""], ["a\nb"], ["é", "e\u{301}"]] {
                model.entries[0].tags = tags; model.prepareReview()
                try expect(model.review.isEmpty && model.error != nil, "invalid labels authorized")
            }
            model.entries[0].tags = ["a,b"]; model.prepareReview()
            try expect(model.review.count == 1 && model.review[0].tagNames == ["a,b"], "comma split into labels")
            model.returnToEditing()
            try expect(model.review.isEmpty, "back kept pending authorization")
        }
        await test("property editor no implicit field change and accurate partial batch results") { dir in
            let good = try file(dir, "good", "good")
            let stale = try file(dir, "stale", "stale")
            let model = FilePropertyEditorModel(); model.load([good, stale])
            while model.isLoading { await Task.yield() }
            model.prepareReview()
            try expect(model.review.isEmpty, "unchecked fields generated changes")
            for index in model.entries.indices { model.entries[index].editPermissions = true; model.entries[index].permissions = "600" }
            model.prepareReview()
            try fm.removeItem(at: stale); _ = try file(dir, "stale", "replacement")
            await model.applyReviewed()
            try expect(model.results.count == 2 && model.results[0].appliedFields == [.permissions] && model.results[0].error == nil,
                       "successful first result lost")
            try expect(model.results[1].appliedFields.isEmpty && model.results[1].error != nil, "stale item reported success")
            try expect(contents(stale) == "replacement", "replacement changed")
            await model.applyReviewed()
            try expect(model.results.count == 2, "completed review reapplied")
        }
        await test("property editor rejects unsupported link without generating an editable snapshot") { dir in
            let file = try file(dir, "target", "data")
            let link = dir.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: file)
            let model = FilePropertyEditorModel(); model.load([link])
            while model.isLoading { await Task.yield() }
            try expect(model.entries.count == 1 && model.entries[0].snapshot == nil && model.entries[0].error != nil,
                       "symlink became editable")
            model.entries[0].editPermissions = true; model.entries[0].permissions = "777"; model.prepareReview()
            try expect(model.review.isEmpty, "unsupported entry authorized")
        }
    }
}
