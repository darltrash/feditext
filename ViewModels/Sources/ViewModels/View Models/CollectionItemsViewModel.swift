// Copyright © 2020 Metabolist. All rights reserved.

import Combine
import Foundation
import Mastodon
import ServiceLayer

// swiftlint:disable file_length
public class CollectionItemsViewModel: ObservableObject {
    public let identityContext: IdentityContext
    @Published public var alertItem: AlertItem?
    public private(set) var nextPageMaxId: String?

    @Published private var lastUpdate = CollectionUpdate(
        sections: [],
        maintainScrollPositionItemId: nil,
        shouldAdjustContentInset: false)
    private let collectionService: CollectionService
    private var viewModelCache = [CollectionItem: (viewModel: CollectionItemViewModel, events: AnyCancellable)]()
    private let eventsSubject = PassthroughSubject<CollectionItemEvent, Never>()
    private let loadingSubject = PassthroughSubject<Bool, Never>()
    private let expandAllSubject: CurrentValueSubject<ExpandAllState, Never>
    private var topVisibleIndexPath = IndexPath(item: 0, section: 0)
    private let lastReadId = CurrentValueSubject<String?, Never>(nil)
    private var lastSelectedLoadMore: LoadMore?
    private var hasRequestedUsingMarker = false
    private var shouldRestorePositionOfLocalLastReadId = false
    private var cancellables = Set<AnyCancellable>()

    public init(collectionService: CollectionService, identityContext: IdentityContext) {
        self.collectionService = collectionService
        self.identityContext = identityContext
        expandAllSubject = CurrentValueSubject(
            collectionService is ContextService && !identityContext.identity.preferences.readingExpandSpoilers
                ? .expand : .hidden)

        collectionService.sections
            .handleEvents(receiveOutput: { [weak self] in self?.process(sections: $0) })
            .receive(on: DispatchQueue.main)
            .assignErrorsToAlertItem(to: \.alertItem, on: self)
            .sink { _ in }
            .store(in: &cancellables)

        collectionService.nextPageMaxId
            .sink { [weak self] in self?.nextPageMaxId = $0 }
            .store(in: &cancellables)

        if let markerTimeline = collectionService.markerTimeline {
            shouldRestorePositionOfLocalLastReadId =
                identityContext.appPreferences.positionBehavior(markerTimeline: markerTimeline) == .rememberPosition
            lastReadId.compactMap { $0 }
                .removeDuplicates()
                .debounce(for: .seconds(Self.lastReadIdDebounceInterval), scheduler: DispatchQueue.global())
                .flatMap { identityContext.service.setLastReadId($0, forMarker: markerTimeline) }
                .sink { _ in } receiveValue: { _ in }
                .store(in: &cancellables)
        }
    }

    public var updates: AnyPublisher<CollectionUpdate, Never> {
        $lastUpdate.eraseToAnyPublisher()
    }

    public func requestNextPage(fromIndexPath indexPath: IndexPath) {
        guard let maxId = collectionService.preferLastPresentIdOverNextPageMaxId
                ? lastUpdate.sections[indexPath.section].items[indexPath.item].itemId
                : nextPageMaxId
        else { return }

        request(maxId: maxId, minId: nil, search: nil)
    }
}

extension CollectionItemsViewModel: CollectionViewModel {
    public var title: AnyPublisher<String, Never> { collectionService.title }

    public var titleLocalizationComponents: AnyPublisher<[String], Never> {
        collectionService.titleLocalizationComponents
    }

    public var expandAll: AnyPublisher<ExpandAllState, Never> {
        expandAllSubject.eraseToAnyPublisher()
    }

    public var alertItems: AnyPublisher<AlertItem, Never> { $alertItem.compactMap { $0 }.eraseToAnyPublisher() }

    public var loading: AnyPublisher<Bool, Never> { loadingSubject.eraseToAnyPublisher() }

    public var events: AnyPublisher<CollectionItemEvent, Never> { eventsSubject.eraseToAnyPublisher() }

    public var canRefresh: Bool { collectionService.canRefresh }

    public func request(maxId: String? = nil, minId: String? = nil, search: Search?) {
        let publisher: AnyPublisher<Never, Error>

        if let markerTimeline = collectionService.markerTimeline,
           identityContext.appPreferences.positionBehavior(markerTimeline: markerTimeline) == .syncPosition,
           !hasRequestedUsingMarker {
            publisher = identityContext.service.getMarker(markerTimeline)
                .flatMap { [weak self] in
                    self?.collectionService.request(maxId: $0.lastReadId, minId: nil, search: nil)
                        ?? Empty().eraseToAnyPublisher()
                }
                .catch { [weak self] _ in
                    self?.collectionService.request(maxId: nil, minId: nil, search: nil)
                        ?? Empty().eraseToAnyPublisher()
                }
                .collect()
                .flatMap { [weak self] _ in
                    self?.collectionService.request(maxId: nil, minId: nil, search: nil)
                        ?? Empty().eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
            self.hasRequestedUsingMarker = true
        } else {
            publisher = collectionService.request(maxId: realMaxId(maxId: maxId), minId: minId, search: search)
        }

        publisher
            .receive(on: DispatchQueue.main)
            .assignErrorsToAlertItem(to: \.alertItem, on: self)
            .handleEvents(
                receiveSubscription: { [weak self] _ in self?.loadingSubject.send(true) },
                receiveCompletion: { [weak self] _ in self?.loadingSubject.send(false) })
            .sink { _ in }
            .store(in: &cancellables)
    }

    public func select(indexPath: IndexPath) {
        let item = lastUpdate.sections[indexPath.section].items[indexPath.item]

        switch item {
        case let .status(status, _):
            eventsSubject.send(
                .navigation(.collection(collectionService
                                            .navigationService
                                            .contextService(id: status.displayStatus.id))))
        case let .loadMore(loadMore):
            lastSelectedLoadMore = loadMore
            (viewModel(indexPath: indexPath) as? LoadMoreViewModel)?.loadMore()
        case let .account(account):
            eventsSubject.send(
                .navigation(.profile(collectionService
                                        .navigationService
                                        .profileService(account: account))))
        case let .notification(notification, _):
            if let status = notification.status {
                eventsSubject.send(
                    .navigation(.collection(collectionService
                                                .navigationService
                                                .contextService(id: status.displayStatus.id))))
            } else {
                eventsSubject.send(
                    .navigation(.profile(collectionService
                                            .navigationService
                                            .profileService(account: notification.account))))
            }
        case let .conversation(conversation):
            guard let status = conversation.lastStatus else { break }

            eventsSubject.send(
                .navigation(.collection(collectionService
                                            .navigationService
                                            .contextService(id: status.displayStatus.id))))
        case let .tag(tag):
            eventsSubject.send(
                .navigation(.collection(collectionService
                                            .navigationService
                                            .timelineService(timeline: .tag(tag.name)))))
        case let .moreResults(moreResults):
            eventsSubject.send(.navigation(.searchScope(moreResults.scope)))
        }
    }

    public func viewedAtTop(indexPath: IndexPath) {
        topVisibleIndexPath = indexPath

        if !shouldRestorePositionOfLocalLastReadId,
           lastUpdate.sections.count > indexPath.section,
           lastUpdate.sections[indexPath.section].items.count > indexPath.item {
            lastReadId.send(lastUpdate.sections[indexPath.section].items[indexPath.item].itemId)
        }
    }

    public func canSelect(indexPath: IndexPath) -> Bool {
        switch lastUpdate.sections[indexPath.section].items[indexPath.item] {
        case let .status(_, configuration):
            return !configuration.isContextParent
        case .loadMore:
            return !((viewModel(indexPath: indexPath) as? LoadMoreViewModel)?.loading ?? false)
        default:
            return true
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public func viewModel(indexPath: IndexPath) -> CollectionItemViewModel {
        let item = lastUpdate.sections[indexPath.section].items[indexPath.item]
        let cachedViewModel = viewModelCache[item]?.viewModel

        switch item {
        case let .status(status, configuration):
            let viewModel: StatusViewModel

            if let cachedViewModel = cachedViewModel as? StatusViewModel {
                viewModel = cachedViewModel
            } else {
                viewModel = .init(
                    statusService: collectionService.navigationService.statusService(status: status),
                    identityContext: identityContext)
                cache(viewModel: viewModel, forItem: item)
            }

            viewModel.configuration = configuration

            return viewModel
        case let .loadMore(loadMore):
            if let cachedViewModel = cachedViewModel {
                return cachedViewModel
            }

            let viewModel = LoadMoreViewModel(
                loadMoreService: collectionService.navigationService.loadMoreService(loadMore: loadMore))

            cache(viewModel: viewModel, forItem: item)

            return viewModel
        case let .account(account):
            if let cachedViewModel = cachedViewModel {
                return cachedViewModel
            }

            let viewModel = AccountViewModel(
                accountService: collectionService.navigationService.accountService(account: account),
                identityContext: identityContext)

            cache(viewModel: viewModel, forItem: item)

            return viewModel
        case let .notification(notification, statusConfiguration):
            let viewModel: CollectionItemViewModel

            if let cachedViewModel = cachedViewModel {
                viewModel = cachedViewModel
            } else if let status = notification.status, let statusConfiguration = statusConfiguration {
                let statusViewModel = StatusViewModel(
                    statusService: collectionService.navigationService.statusService(status: status),
                    identityContext: identityContext)
                statusViewModel.configuration = statusConfiguration
                viewModel = statusViewModel
                cache(viewModel: viewModel, forItem: item)
            } else {
                viewModel = NotificationViewModel(
                    notificationService: collectionService.navigationService.notificationService(
                        notification: notification),
                    identityContext: identityContext)
                cache(viewModel: viewModel, forItem: item)
            }

            return viewModel
        case let .conversation(conversation):
            if let cachedViewModel = cachedViewModel {
                return cachedViewModel
            }

            let viewModel = ConversationViewModel(
                conversationService: collectionService.navigationService.conversationService(
                    conversation: conversation),
                identityContext: identityContext)

            cache(viewModel: viewModel, forItem: item)

            return viewModel
        case let .tag(tag):
            if let cachedViewModel = cachedViewModel {
                return cachedViewModel
            }

            let viewModel = TagViewModel(tag: tag)

            cache(viewModel: viewModel, forItem: item)

            return viewModel
        case let .moreResults(moreResults):
            if let cachedViewModel = cachedViewModel {
                return cachedViewModel
            }

            let viewModel = MoreResultsViewModel(moreResults: moreResults)

            cache(viewModel: viewModel, forItem: item)

            return viewModel
        }
    }

    public func toggleExpandAll() {
        let statusIds = Set(lastUpdate.sections.map(\.items).reduce([], +).compactMap { item -> Status.Id? in
            guard case let .status(status, _) = item else { return nil }

            return status.id
        })

        switch expandAllSubject.value {
        case .hidden:
            break
        case .expand:
            (collectionService as? ContextService)?.expand(ids: statusIds)
                .assignErrorsToAlertItem(to: \.alertItem, on: self)
                .collect()
                .sink { [weak self] _ in self?.expandAllSubject.send(.collapse) }
                .store(in: &cancellables)
        case .collapse:
            (collectionService as? ContextService)?.collapse(ids: statusIds)
                .assignErrorsToAlertItem(to: \.alertItem, on: self)
                .collect()
                .sink { [weak self] _ in self?.expandAllSubject.send(.expand) }
                .store(in: &cancellables)
        }
    }
}

private extension CollectionItemsViewModel {
    private static let lastReadIdDebounceInterval: TimeInterval = 0.5

    var lastUpdateWasContextParentOnly: Bool {
        collectionService is ContextService && lastUpdate.sections.map(\.items).map(\.count) == [0, 1, 0]
    }

    func cache(viewModel: CollectionItemViewModel, forItem item: CollectionItem) {
        viewModelCache[item] = (viewModel, viewModel.events
                                    .flatMap { [weak self] events -> AnyPublisher<CollectionItemEvent, Never> in
                                        guard let self = self else { return Empty().eraseToAnyPublisher() }

                                        return events.assignErrorsToAlertItem(to: \.alertItem, on: self)
                                            .eraseToAnyPublisher()
                                    }
                                    .sink { [weak self] in self?.eventsSubject.send($0) })
    }

    func process(sections: [CollectionSection]) {
        let items = sections.map(\.items).reduce([], +)
        let itemsSet = Set(items)

        self.lastUpdate = .init(
            sections: sections,
            maintainScrollPositionItemId: idForScrollPositionMaintenance(newSections: sections),
            shouldAdjustContentInset: lastUpdateWasContextParentOnly && items.count > 1)

        viewModelCache = viewModelCache.filter { itemsSet.contains($0.key) }
    }

    func realMaxId(maxId: String?) -> String? {
        guard let maxId = maxId else { return nil }

        guard let markerTimeline = collectionService.markerTimeline,
              identityContext.appPreferences.positionBehavior(markerTimeline: markerTimeline) == .rememberPosition,
              let lastItemId = lastUpdate.sections.last?.items.last?.itemId
        else { return maxId }

        return min(maxId, lastItemId)
    }

    func idForScrollPositionMaintenance(newSections: [CollectionSection]) -> CollectionItem.Id? {
        let items = lastUpdate.sections.map(\.items).reduce([], +)
        let newItems = newSections.map(\.items).reduce([], +)

        if shouldRestorePositionOfLocalLastReadId,
           let markerTimeline = collectionService.markerTimeline,
           let localLastReadId = identityContext.service.getLocalLastReadId(markerTimeline),
           newItems.contains(where: { $0.itemId == localLastReadId }) {
            shouldRestorePositionOfLocalLastReadId = false

            return localLastReadId
        }

        if collectionService is ContextService,
           lastUpdate.sections.isEmpty || lastUpdate.sections.map(\.items.count) == [0, 1, 0],
           let contextParent = newItems.first(where: {
            guard case let .status(_, configuration) = $0 else { return false }

            return configuration.isContextParent // Maintain scroll position of parent after initial load of context
           }) {
            return contextParent.itemId
        } else if collectionService is TimelineService {
            let difference = newItems.difference(from: items)

            if let lastSelectedLoadMore = lastSelectedLoadMore {
                for removal in difference.removals {
                    if case let .remove(_, item, _) = removal,
                       case let .loadMore(loadMore) = item,
                       loadMore == lastSelectedLoadMore,
                       let direction = (viewModelCache[item]?.viewModel as? LoadMoreViewModel)?.direction,
                       direction == .up,
                       let statusAfterLoadMore = items.first(where: {
                        guard case let .status(status, _) = $0 else { return false }

                        return status.id == loadMore.beforeStatusId
                       }) {
                        return statusAfterLoadMore.itemId
                    }
                }
            }

            if lastUpdate.sections.count > topVisibleIndexPath.section,
               lastUpdate.sections[topVisibleIndexPath.section].items.count > topVisibleIndexPath.item {
                let topVisibleItem = lastUpdate.sections[topVisibleIndexPath.section].items[topVisibleIndexPath.item]

                if newSections.count > topVisibleIndexPath.section,
                   let newIndex = newSections[topVisibleIndexPath.section]
                    .items.firstIndex(where: { $0.itemId == topVisibleItem.itemId }),
                   newIndex > topVisibleIndexPath.item {
                    return topVisibleItem.itemId
                }
            }
        }

        return nil
    }
}
// swiftlint:enable file_length