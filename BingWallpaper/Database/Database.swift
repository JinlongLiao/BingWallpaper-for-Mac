//
//  Database.swift
//  BingWallpaper
//
//  Created by Laurenz Lazarus on 24.03.24.
//

import Foundation
import Cocoa
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Database.rawValue
)

@MainActor
final class Database {
    enum Error: LocalizedError {
        case noValidMetadata
        case persistentStoreUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noValidMetadata:
                return L("The wallpaper source returned no valid wallpaper metadata")
            case .persistentStoreUnavailable(let message):
                return L("The wallpaper database is unavailable: %@", message)
            }
        }
    }

    struct ImageDescriptorUpdate {
        let descriptors: [ImageDescriptor]
        let wallpaperIDsRequiringDownload: Set<String>
    }

    static let instance = Database()

    private(set) var recoveryNotice: String?

    private init() { }

    init(inMemory: Bool) {
        self.useInMemoryStore = inMemory
    }

    private var useInMemoryStore = false
    
    @MainActor
    func allImageDescriptors() -> [ImageDescriptor] {
        return fetchImageDescriptorsOrEmpty()
    }

    @MainActor
    func allImageDescriptors(marketCode: String?) -> [ImageDescriptor] {
        return fetchImageDescriptorsOrEmpty(predicate: marketPredicate(marketCode))
    }

    @MainActor
    private func fetchImageDescriptors(predicate: NSPredicate? = nil) throws -> [ImageDescriptor] {
        let fetchRequest = NSFetchRequest<ImageDescriptor>(entityName: "ImageDescriptor")
        fetchRequest.predicate = predicate
        fetchRequest.sortDescriptors = [
            NSSortDescriptor(key: "startDate", ascending: true),
            NSSortDescriptor(key: "lastSeenAt", ascending: true),
            NSSortDescriptor(key: "marketCode", ascending: true)
        ]
        
        // Wallpaper Alchemy 同一天有多张图片，需按图片编号细排，存储层无法表达该规则。
        return try persistentContainer.viewContext.fetch(fetchRequest).sorted()
    }

    private func fetchImageDescriptorsOrEmpty(
        predicate: NSPredicate? = nil
    ) -> [ImageDescriptor] {
        do {
            return try fetchImageDescriptors(predicate: predicate)
        } catch let error as NSError {
            logger.error("Could not fetch. \(error, privacy: .public), \(error.userInfo, privacy: .public)")
            return []
        }
    }

    private func marketPredicate(_ marketCode: String?) -> NSPredicate {
        if let marketCode {
            return NSPredicate(format: "marketCode == %@", marketCode)
        }
        return NSPredicate(format: "marketCode == nil")
    }
    
    @MainActor
    @discardableResult
    func deleteImageDescriptors(
        exceedingMaximumCount maximumCount: Int,
        preserving wallpaperIDs: Set<String> = []
    ) throws -> Set<String> {
        let managedContext = persistentContainer.viewContext
        let allDescriptors = try fetchImageDescriptors()
        let numberToDelete = max(0, allDescriptors.count - max(0, maximumCount))
        let descriptorsToDelete = allDescriptors.prefix(numberToDelete)
            .filter {
                wallpaperIDs.contains($0.wallpaperIdentifier) == false
            }
        let deletedObjectIDs = Set(descriptorsToDelete.map(\.objectID))
        let remainingFileNames = Set(allDescriptors.compactMap { descriptor in
            deletedObjectIDs.contains(descriptor.objectID) ? nil : descriptor.image.fileName
        })
        let deletedFileNames = Set(descriptorsToDelete.map { $0.image.fileName })
            .subtracting(remainingFileNames)
        descriptorsToDelete.forEach { managedContext.delete($0) }
        
        do {
            try managedContext.save()
        } catch {
            managedContext.rollback()
            throw error
        }
        return deletedFileNames
    }

    @MainActor
    func deleteAllImageDescriptors() throws {
        let managedContext = persistentContainer.viewContext
        try fetchImageDescriptors().forEach { managedContext.delete($0) }
        do {
            try managedContext.save()
        } catch {
            managedContext.rollback()
            throw error
        }
    }
    
    @MainActor
    func updateImageDescriptors(
        from imageEntries: [DownloadManager.ImageEntry],
        marketCode: String?
    ) throws -> ImageDescriptorUpdate {
        return try updateImageDescriptors(
            from: Self.validMetadata(from: imageEntries) {
                try ImageDescriptor.validatedMetadata(from: $0)
            },
            marketCode: marketCode
        )
    }

    /// 保存 Wallpaper Alchemy 当天轮换到的壁纸元数据，列表顺序即排行名次。
    /// - Parameters:
    ///   - imageEntries: 接口返回的壁纸列表，按下载量从高到低排列。
    ///   - locale: 请求所用的站点语言。
    ///   - featuredAt: 本次获取列表的时间，决定展示日期。
    @MainActor
    func updateWallpaperAlchemyImageDescriptors(
        from imageEntries: [DownloadManager.WallpaperAlchemyEntry],
        locale: String,
        featuredAt: Date = Date()
    ) throws -> ImageDescriptorUpdate {
        return try updateImageDescriptors(
            from: Self.validMetadata(from: Array(imageEntries.enumerated())) {
                try ImageDescriptor.validatedMetadata(
                    from: $0.element,
                    locale: locale,
                    featuredAt: featuredAt,
                    rank: $0.offset
                )
            },
            marketCode: WallpaperChannel.wallpaperAlchemyCode
        )
    }

    private static func validMetadata<Entry>(
        from entries: [Entry],
        validate: (Entry) throws -> ImageDescriptor.ValidatedMetadata
    ) -> [ImageDescriptor.ValidatedMetadata] {
        return entries.compactMap { entry in
            do {
                return try validate(entry)
            } catch {
                logger.error("Skipping invalid wallpaper metadata: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    @MainActor
    func updateImageDescriptors(
        from validatedMetadata: [ImageDescriptor.ValidatedMetadata],
        marketCode: String?
    ) throws -> ImageDescriptorUpdate {
        let managedContext = persistentContainer.viewContext
        var descriptorByIdentity = try fetchImageDescriptors(
            predicate: marketPredicate(marketCode)
        )
            .reduce(into: [String: ImageDescriptor]()) { descriptors, descriptor in
                let identity = ImageDescriptor.archiveIdentity(
                    startDate: descriptor.startDate,
                    marketCode: descriptor.marketCode,
                    imageURL: descriptor.imageUrl
                )
                descriptors[identity] = descriptor
            }
        var wallpaperIDsRequiringDownload = Set<String>()
        var validMetadataCount = 0
        var currentDescriptors = [ImageDescriptor]()
        
        for metadata in validatedMetadata {
            do {
                let archiveIdentity = ImageDescriptor.archiveIdentity(
                    startDate: metadata.startDate,
                    marketCode: marketCode,
                    imageURL: metadata.imageURL
                )
                if let existingDescriptor = descriptorByIdentity[archiveIdentity] {
                    if existingDescriptor.update(from: metadata) {
                        wallpaperIDsRequiringDownload.insert(existingDescriptor.wallpaperIdentifier)
                    }
                    if existingDescriptor.requiresImageDownload {
                        wallpaperIDsRequiringDownload.insert(existingDescriptor.wallpaperIdentifier)
                    }
                    currentDescriptors.append(existingDescriptor)
                    validMetadataCount += 1
                } else {
                    let descriptor = try ImageDescriptor.instantiate(
                        from: metadata,
                        marketCode: marketCode,
                        in: managedContext
                    )
                    descriptorByIdentity[archiveIdentity] = descriptor
                    currentDescriptors.append(descriptor)
                    validMetadataCount += 1
                }
            } catch {
                logger.error("Skipping wallpaper metadata that could not be stored: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        guard validMetadataCount > 0 else {
            managedContext.rollback()
            throw Error.noValidMetadata
        }

        do {
            try managedContext.save()
        } catch let error as NSError {
            managedContext.rollback()
            logger.error("Could not save. \(error, privacy: .public), \(error.userInfo, privacy: .public)")
            throw error
        }
        
        return ImageDescriptorUpdate(
            descriptors: currentDescriptors,
            wallpaperIDsRequiringDownload: wallpaperIDsRequiringDownload
        )
    }

    func markImageDownloadCompleted(for descriptor: ImageDescriptor) throws {
        guard descriptor.requiresImageDownload else { return }
        let managedContext = persistentContainer.viewContext
        descriptor.requiresImageDownload = false
        do {
            try managedContext.save()
        } catch {
            managedContext.rollback()
            throw error
        }
    }
    
    
    // MARK: - Core Data stack
    
    private func entityDescription() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "ImageDescriptor"
        entity.managedObjectClassName = NSStringFromClass(ImageDescriptor.self)
        
        // Attributes
        let startDateAttr = NSAttributeDescription()
        startDateAttr.name = "startDate"
        startDateAttr.attributeType = .stringAttributeType
        startDateAttr.isOptional = false
        
        let endDateAttr = NSAttributeDescription()
        endDateAttr.name = "endDate"
        endDateAttr.attributeType = .stringAttributeType
        endDateAttr.isOptional = false
        
        let imageUrlAttr = NSAttributeDescription()
        imageUrlAttr.name = "imageUrl"
        imageUrlAttr.attributeType = .URIAttributeType
        imageUrlAttr.isOptional = false
        
        let descriptionStringAttr = NSAttributeDescription()
        descriptionStringAttr.name = "descriptionString"
        descriptionStringAttr.attributeType = .stringAttributeType
        descriptionStringAttr.isOptional = false
        
        let copyrightUrlAttr = NSAttributeDescription()
        copyrightUrlAttr.name = "copyrightUrl"
        copyrightUrlAttr.attributeType = .URIAttributeType
        copyrightUrlAttr.isOptional = false

        let marketCodeAttr = NSAttributeDescription()
        marketCodeAttr.name = "marketCode"
        marketCodeAttr.attributeType = .stringAttributeType
        marketCodeAttr.isOptional = true

        let requiresImageDownloadAttr = NSAttributeDescription()
        requiresImageDownloadAttr.name = "requiresImageDownload"
        requiresImageDownloadAttr.attributeType = .booleanAttributeType
        requiresImageDownloadAttr.isOptional = false
        requiresImageDownloadAttr.defaultValue = false

        let lastSeenAtAttr = NSAttributeDescription()
        lastSeenAtAttr.name = "lastSeenAt"
        lastSeenAtAttr.attributeType = .dateAttributeType
        lastSeenAtAttr.isOptional = true
        
        entity.properties = [
            startDateAttr,
            endDateAttr,
            imageUrlAttr,
            descriptionStringAttr,
            copyrightUrlAttr,
            marketCodeAttr,
            requiresImageDownloadAttr,
            lastSeenAtAttr
        ]
        
        return entity
    }
    
    private func managedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [entityDescription()]
        return model
    }
    
    private final class StoreLoadResult: @unchecked Sendable {
        var error: NSError?
    }

    private func makePersistentContainer(inMemory: Bool) -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "DataModel",
            managedObjectModel: managedObjectModel()
        )
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
        } else {
            container.persistentStoreDescriptions.forEach {
                $0.shouldAddStoreAsynchronously = false
                $0.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
                $0.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            }
        }
        return container
    }

    private func loadPersistentStores(into container: NSPersistentContainer) -> NSError? {
        let result = StoreLoadResult()
        container.loadPersistentStores { _, error in
            result.error = error as NSError?
        }
        return result.error
    }

    private func backupCorruptStore(at storeURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("CorruptStore-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.moveItem(
                at: source,
                to: backupDirectory.appendingPathComponent(source.lastPathComponent)
            )
        }
        return backupDirectory
    }

    lazy var persistentContainer: NSPersistentContainer = {
        let initialContainer = makePersistentContainer(inMemory: useInMemoryStore)
        guard let initialError = loadPersistentStores(into: initialContainer) else {
            return initialContainer
        }

        logger.fault("Failed to load the wallpaper database: \(initialError, privacy: .public)")
        guard useInMemoryStore == false,
              let storeURL = initialContainer.persistentStoreDescriptions.first?.url else {
            recoveryNotice = Error.persistentStoreUnavailable(
                initialError.localizedDescription
            ).localizedDescription
            return initialContainer
        }

        do {
            let backupDirectory = try backupCorruptStore(at: storeURL)
            let replacementContainer = makePersistentContainer(inMemory: false)
            if let replacementError = loadPersistentStores(into: replacementContainer) {
                throw replacementError
            }
            recoveryNotice = L("The wallpaper database was damaged and has been rebuilt. A backup was saved at %@.", backupDirectory.path)
            logger.fault("Rebuilt the wallpaper database after moving the damaged store to \(backupDirectory.path, privacy: .public)")
            return replacementContainer
        } catch {
            let fallbackContainer = makePersistentContainer(inMemory: true)
            let fallbackError = loadPersistentStores(into: fallbackContainer)
            recoveryNotice = L("The wallpaper database could not be opened. BingWallpaper is using a temporary in-memory database for this session. %@", (fallbackError ?? error as NSError).localizedDescription)
            logger.fault("Falling back to an in-memory wallpaper database: \(error.localizedDescription, privacy: .public)")
            return fallbackContainer
        }
    }()
}
