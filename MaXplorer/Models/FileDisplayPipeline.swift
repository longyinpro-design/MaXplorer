import Foundation

/// Shared by folder filtering and recursive results; metadata is already loaded.
nonisolated enum FileDisplayPipeline {
    static func displayedItems(
        from items: [FileItem], descriptor: FileSortDescriptor, query: String, showAliases: Bool
    ) -> [FileItem] {
        let filtered: [FileItem]
        if query.isEmpty && showAliases {
            filtered = items
        } else {
            filtered = items.filter { item in
                (showAliases || !item.isAlias)
                    && (query.isEmpty || SearchMatchMode.contains.matches(item.name, query: query))
            }
        }
        return FileSorter.sorted(filtered, by: descriptor)
    }
}
