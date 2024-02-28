//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import SignalCoreKit
import SignalServiceKit

// MARK: - OWSContactsMangerSwiftValues

class OWSContactsManagerSwiftValues {

    fileprivate var systemContactsCache: SystemContactsCache?

    fileprivate let systemContactsDataProvider = AtomicOptional<SystemContactsDataProvider>(nil)

    fileprivate var primaryDeviceSystemContactsDataProvider: PrimaryDeviceSystemContactsDataProvider? {
        systemContactsDataProvider.get() as? PrimaryDeviceSystemContactsDataProvider
    }

    fileprivate let usernameLookupManager: UsernameLookupManager

    init(usernameLookupManager: UsernameLookupManager) {
        self.usernameLookupManager = usernameLookupManager
    }
}

// TODO: Should we use these caches in NSE?
private extension OWSContactsManager {
    static let skipContactAvatarBlurByServiceIdStore = SDSKeyValueStore(collection: "OWSContactsManager.skipContactAvatarBlurByUuidStore")
    static let skipGroupAvatarBlurByGroupIdStore = SDSKeyValueStore(collection: "OWSContactsManager.skipGroupAvatarBlurByGroupIdStore")

    // MARK: - Low Trust

    private enum LowTrustType {
        case avatarBlurring
        case unknownThreadWarning

        var checkForTrustedGroupMembers: Bool {
            self == .unknownThreadWarning
        }

        var cache: LowTrustCache {
            switch self {
            case .avatarBlurring:
                return OWSContactsManager.avatarBlurringCache
            case .unknownThreadWarning:
                return OWSContactsManager.unknownThreadWarningCache
            }
        }
    }

    private struct LowTrustCache {
        let contactCache = AtomicSet<ServiceId>()
        let groupCache = AtomicSet<Data>()

        func contains(groupThread: TSGroupThread) -> Bool {
            groupCache.contains(groupThread.groupId)
        }

        func contains(contactThread: TSContactThread) -> Bool {
            contains(address: contactThread.contactAddress)
        }

        func contains(address: SignalServiceAddress) -> Bool {
            guard let serviceId = address.serviceId else {
                return false
            }
            return contactCache.contains(serviceId)
        }

        func add(groupThread: TSGroupThread) {
            groupCache.insert(groupThread.groupId)
        }

        func add(contactThread: TSContactThread) {
            add(address: contactThread.contactAddress)
        }

        func add(address: SignalServiceAddress) {
            guard let serviceId = address.serviceId else {
                return
            }
            contactCache.insert(serviceId)
        }
    }

    private static let unknownThreadWarningCache = LowTrustCache()
    private static let avatarBlurringCache = LowTrustCache()

    private func isLowTrustThread(_ thread: TSThread, lowTrustType: LowTrustType, transaction tx: SDSAnyReadTransaction) -> Bool {
        if let contactThread = thread as? TSContactThread {
            return isLowTrustContact(contactThread: contactThread, lowTrustType: lowTrustType, tx: tx)
        } else if let groupThread = thread as? TSGroupThread {
            return isLowTrustGroup(groupThread: groupThread, lowTrustType: lowTrustType, tx: tx)
        } else {
            owsFailDebug("Invalid thread.")
            return false
        }
    }

    private func isLowTrustContact(address: SignalServiceAddress, lowTrustType: LowTrustType, transaction tx: SDSAnyReadTransaction) -> Bool {
        let cache = lowTrustType.cache
        if cache.contains(address: address) {
            return false
        }
        guard let contactThread = TSContactThread.getWithContactAddress(address, transaction: tx) else {
            cache.add(address: address)
            return false
        }
        return isLowTrustContact(contactThread: contactThread, lowTrustType: lowTrustType, tx: tx)
    }

    private func isLowTrustContact(contactThread: TSContactThread, lowTrustType: LowTrustType, tx: SDSAnyReadTransaction) -> Bool {
        let cache = lowTrustType.cache
        let address = contactThread.contactAddress
        if cache.contains(address: address) {
            return false
        }
        if !contactThread.hasPendingMessageRequest(transaction: tx) {
            cache.add(address: address)
            return false
        }
        // ...and not in a whitelisted group with the locar user.
        if isInWhitelistedGroupWithLocalUser(otherAddress: address, tx: tx) {
            cache.add(address: address)
            return false
        }
        // We can skip avatar blurring if the user has explicitly waived the blurring.
        if
            lowTrustType == .avatarBlurring,
            let storeKey = address.serviceId?.serviceIdUppercaseString,
            Self.skipContactAvatarBlurByServiceIdStore.getBool(storeKey, defaultValue: false, transaction: tx)
        {
            cache.add(address: address)
            return false
        }
        return true
    }

    private func isLowTrustGroup(groupThread: TSGroupThread, lowTrustType: LowTrustType, tx: SDSAnyReadTransaction) -> Bool {
        let cache = lowTrustType.cache
        let groupId = groupThread.groupId
        if cache.contains(groupThread: groupThread) {
            return false
        }
        if nil == groupThread.groupModel.avatarHash {
            // DO NOT add to the cache.
            return false
        }
        if !groupThread.hasPendingMessageRequest(transaction: tx) {
            cache.add(groupThread: groupThread)
            return false
        }
        // We can skip avatar blurring if the user has explicitly waived the blurring.
        if
            lowTrustType == .avatarBlurring,
            Self.skipGroupAvatarBlurByGroupIdStore.getBool(groupId.hexadecimalString, defaultValue: false, transaction: tx)
        {
            cache.add(groupThread: groupThread)
            return false
        }
        // We can skip "unknown thread warnings" if a group has members which are trusted.
        if lowTrustType.checkForTrustedGroupMembers, hasWhitelistedGroupMember(groupThread: groupThread, tx: tx) {
            cache.add(groupThread: groupThread)
            return false
        }
        return true
    }

    // MARK: -

    private static let isInWhitelistedGroupWithLocalUserCache = AtomicDictionary<ServiceId, Bool>()

    private func isInWhitelistedGroupWithLocalUser(otherAddress: SignalServiceAddress, tx: SDSAnyReadTransaction) -> Bool {
        let cache = Self.isInWhitelistedGroupWithLocalUserCache
        if let cacheKey = otherAddress.serviceId, let cachedValue = cache[cacheKey] {
            return cachedValue
        }
        let result: Bool = {
            guard let localAddress = DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aciAddress else {
                owsFailDebug("Missing localAddress.")
                return false
            }
            let otherGroupThreadIds = TSGroupThread.groupThreadIds(with: otherAddress, transaction: tx)
            guard !otherGroupThreadIds.isEmpty else {
                return false
            }
            let localGroupThreadIds = TSGroupThread.groupThreadIds(with: localAddress, transaction: tx)
            let groupThreadIds = Set(otherGroupThreadIds).intersection(localGroupThreadIds)
            for groupThreadId in groupThreadIds {
                guard let groupThread = TSGroupThread.anyFetchGroupThread(uniqueId: groupThreadId, transaction: tx) else {
                    owsFailDebug("Missing group thread")
                    continue
                }
                if profileManager.isGroupId(inProfileWhitelist: groupThread.groupId, transaction: tx) {
                    return true
                }
            }
            return false
        }()
        if let cacheKey = otherAddress.serviceId {
            cache[cacheKey] = result
        }
        return result
    }

    private static let hasWhitelistedGroupMemberCache = AtomicDictionary<Data, Bool>()

    private func hasWhitelistedGroupMember(groupThread: TSGroupThread, tx: SDSAnyReadTransaction) -> Bool {
        let cache = Self.hasWhitelistedGroupMemberCache
        let cacheKey = groupThread.groupId
        if let cachedValue = cache[cacheKey] {
            return cachedValue
        }
        let result: Bool = {
            for groupMember in groupThread.groupMembership.fullMembers {
                if profileManager.isUser(inProfileWhitelist: groupMember, transaction: tx) {
                    return true
                }
            }
            return false
        }()
        cache[cacheKey] = result
        return result
    }
}

// MARK: -

public extension OWSContactsManager {

    // MARK: - Low Trust Thread Warnings

    func shouldShowUnknownThreadWarning(thread: TSThread, transaction: SDSAnyReadTransaction) -> Bool {
        isLowTrustThread(thread, lowTrustType: .unknownThreadWarning, transaction: transaction)
    }

    // MARK: - Avatar Blurring

    func shouldBlurAvatar(thread: TSThread, transaction: SDSAnyReadTransaction) -> Bool {
        isLowTrustThread(thread, lowTrustType: .avatarBlurring, transaction: transaction)
    }

    func shouldBlurContactAvatar(address: SignalServiceAddress, transaction: SDSAnyReadTransaction) -> Bool {
        isLowTrustContact(address: address, lowTrustType: .avatarBlurring, transaction: transaction)
    }

    func shouldBlurContactAvatar(contactThread: TSContactThread, transaction: SDSAnyReadTransaction) -> Bool {
        isLowTrustContact(contactThread: contactThread, lowTrustType: .avatarBlurring, tx: transaction)
    }

    func shouldBlurGroupAvatar(groupThread: TSGroupThread, transaction: SDSAnyReadTransaction) -> Bool {
        isLowTrustGroup(groupThread: groupThread, lowTrustType: .avatarBlurring, tx: transaction)
    }

    static let skipContactAvatarBlurDidChange = NSNotification.Name("skipContactAvatarBlurDidChange")
    static let skipContactAvatarBlurAddressKey = "skipContactAvatarBlurAddressKey"
    static let skipGroupAvatarBlurDidChange = NSNotification.Name("skipGroupAvatarBlurDidChange")
    static let skipGroupAvatarBlurGroupUniqueIdKey = "skipGroupAvatarBlurGroupUniqueIdKey"

    func doNotBlurContactAvatar(address: SignalServiceAddress, transaction tx: SDSAnyWriteTransaction) {
        guard let serviceId = address.serviceId else {
            owsFailDebug("Missing ServiceId for user.")
            return
        }
        let storeKey = serviceId.serviceIdUppercaseString
        let shouldSkipBlur = Self.skipContactAvatarBlurByServiceIdStore.getBool(storeKey, defaultValue: false, transaction: tx)
        guard !shouldSkipBlur else {
            owsFailDebug("Value did not change.")
            return
        }
        Self.skipContactAvatarBlurByServiceIdStore.setBool(true, key: storeKey, transaction: tx)
        if let contactThread = TSContactThread.getWithContactAddress(address, transaction: tx) {
            databaseStorage.touch(thread: contactThread, shouldReindex: false, transaction: tx)
        }
        tx.addAsyncCompletionOffMain {
            NotificationCenter.default.postNotificationNameAsync(
                Self.skipContactAvatarBlurDidChange,
                object: nil,
                userInfo: [
                    Self.skipContactAvatarBlurAddressKey: address
                ]
            )
        }
    }

    func doNotBlurGroupAvatar(groupThread: TSGroupThread, transaction: SDSAnyWriteTransaction) {
        let groupId = groupThread.groupId
        let groupUniqueId = groupThread.uniqueId
        guard !Self.skipGroupAvatarBlurByGroupIdStore.getBool(groupId.hexadecimalString,
                                                              defaultValue: false,
                                                              transaction: transaction) else {
            owsFailDebug("Value did not change.")
            return
        }
        Self.skipGroupAvatarBlurByGroupIdStore.setBool(true,
                                                       key: groupId.hexadecimalString,
                                                       transaction: transaction)
        databaseStorage.touch(thread: groupThread, shouldReindex: false, transaction: transaction)

        transaction.addAsyncCompletionOffMain {
            NotificationCenter.default.postNotificationNameAsync(Self.skipGroupAvatarBlurDidChange,
                                                                 object: nil,
                                                                 userInfo: [
                                                                    Self.skipGroupAvatarBlurGroupUniqueIdKey: groupUniqueId
                                                                 ])
        }
    }

    func blurAvatar(_ image: UIImage) -> UIImage? {
        do {
            return try image.withGaussianBlur(radius: 16, resizeToMaxPixelDimension: 100)
        } catch {
            owsFailDebug("Error: \(error)")
            return nil
        }
    }

    // MARK: -

    @objc
    @available(swift, obsoleted: 1.0)
    func _sortSignalServiceAddressesObjC(_ addresses: [SignalServiceAddress], transaction: SDSAnyReadTransaction) -> [SignalServiceAddress] {
        sortSignalServiceAddresses(addresses, transaction: transaction)
    }

    // MARK: -

    func shortestDisplayName(
        forGroupMember groupMember: SignalServiceAddress,
        inGroup groupModel: TSGroupModel,
        transaction: SDSAnyReadTransaction
    ) -> String {

        let fullName = displayName(for: groupMember, transaction: transaction)
        let shortName = shortDisplayName(for: groupMember, transaction: transaction)
        guard shortName != fullName else { return fullName }

        // Try to return just the short name unless the group contains another
        // member with the same short name.

        for otherMember in groupModel.groupMembership.fullMembers {
            guard otherMember != groupMember else { continue }

            // Use the full name if the member's short name matches
            // another member's full or short name.
            let otherFullName = displayName(for: otherMember, transaction: transaction)
            guard otherFullName != shortName else { return fullName }

            let otherShortName = shortDisplayName(for: otherMember, transaction: transaction)
            guard otherShortName != shortName else { return fullName }
        }

        return shortName
    }
}

// MARK: -

public struct SortableAddress: Equatable, Comparable {
    public let address: SignalServiceAddress
    public let comparableName: String
    private let comparableAddress: String

    init(address: SignalServiceAddress, comparableName: String) {
        self.address = address
        self.comparableName = comparableName.lowercased()
        self.comparableAddress = address.stringForDisplay
    }

    // MARK: - Equatable

    public static func == (lhs: SortableAddress, rhs: SortableAddress) -> Bool {
        return (
            lhs.comparableName == rhs.comparableName
            && lhs.comparableAddress == rhs.comparableAddress
        )
    }

    // MARK: - Comparable

    public static func < (lhs: SortableAddress, rhs: SortableAddress) -> Bool {
        // We want to sort E164 phone numbers _after_ names.
        switch (lhs.comparableName.hasPrefix("+"), rhs.comparableName.hasPrefix("+")) {
        case (true, true), (false, false):
            break
        case (true, false):
            return false
        case (false, true):
            return true
        }

        if lhs.comparableName != rhs.comparableName {
            return lhs.comparableName < rhs.comparableName
        }

        return lhs.comparableAddress < rhs.comparableAddress
    }
}

// MARK: -

extension OWSContactsManager {

    @objc
    public func avatarImage(forAddress address: SignalServiceAddress?,
                            shouldValidate: Bool,
                            transaction: SDSAnyReadTransaction) -> UIImage? {
        guard let imageData = avatarImageData(forAddress: address,
                                              shouldValidate: shouldValidate,
                                              transaction: transaction) else {
            return nil
        }
        guard let image = UIImage(data: imageData) else {
            owsFailDebug("Invalid image.")
            return nil
        }
        return image
    }

    @objc
    public func avatarImageData(forAddress address: SignalServiceAddress?,
                                shouldValidate: Bool,
                                transaction: SDSAnyReadTransaction) -> Data? {
        guard let address = address,
              address.isValid else {
                  owsFailDebug("Missing or invalid address.")
                  return nil
              }

        if SSKPreferences.preferContactAvatars(transaction: transaction) {
            return (systemContactOrSyncedImageData(forAddress: address,
                                                   shouldValidate: shouldValidate,
                                                   transaction: transaction)
                    ?? profileAvatarImageData(forAddress: address,
                                              shouldValidate: shouldValidate,
                                              transaction: transaction))
        } else {
            return (profileAvatarImageData(forAddress: address,
                                           shouldValidate: shouldValidate,
                                           transaction: transaction)
                    ?? systemContactOrSyncedImageData(forAddress: address,
                                                      shouldValidate: shouldValidate,
                                                      transaction: transaction))
        }
    }

    fileprivate func profileAvatarImageData(forAddress address: SignalServiceAddress?,
                                            shouldValidate: Bool,
                                            transaction: SDSAnyReadTransaction) -> Data? {
        func validateIfNecessary(_ imageData: Data) -> Data? {
            guard shouldValidate else {
                return imageData
            }
            guard imageData.ows_isValidImage else {
                owsFailDebug("Invalid image data.")
                return nil
            }
            return imageData
        }

        guard let address = address,
              address.isValid else {
                  owsFailDebug("Missing or invalid address.")
                  return nil
              }

        if let avatarData = profileManagerImpl.profileAvatarData(for: address, transaction: transaction),
           let validData = validateIfNecessary(avatarData) {
            return validData
        }

        return nil
    }

    fileprivate func systemContactOrSyncedImageData(forAddress address: SignalServiceAddress?,
                                                    shouldValidate: Bool,
                                                    transaction: SDSAnyReadTransaction) -> Data? {
        func validateIfNecessary(_ imageData: Data) -> Data? {
            guard shouldValidate else {
                return imageData
            }
            guard imageData.ows_isValidImage else {
                owsFailDebug("Invalid image data.")
                return nil
            }
            return imageData
        }

        guard let address = address,
              address.isValid else {
                  owsFailDebug("Missing or invalid address.")
                  return nil
              }

        guard !address.isLocalAddress else {
            // Never use system contact or synced image data for the local user
            return nil
        }

        if
            let phoneNumber = address.phoneNumber,
            let contact = contact(forPhoneNumber: phoneNumber, transaction: transaction),
            let cnContactId = contact.cnContactId,
            let avatarData = self.avatarData(forCNContactId: cnContactId),
            let validData = validateIfNecessary(avatarData)
        {
            return validData
        }

        // If we haven't loaded system contacts yet, we may have a cached copy in the db
        if let signalAccount = self.fetchSignalAccount(for: address, transaction: transaction) {
            if let contact = signalAccount.contact,
               let cnContactId = contact.cnContactId,
               let avatarData = self.avatarData(forCNContactId: cnContactId),
               let validData = validateIfNecessary(avatarData) {
                return validData
            }

            if let contactAvatarData = signalAccount.buildContactAvatarJpegData() {
                return contactAvatarData
            }
        }
        return nil
    }
}

// MARK: - Internals

extension OWSContactsManager {
    // TODO: It would be preferable to figure out some way to use ReverseDispatchQueue.
    @objc
    static let intersectionQueue = DispatchQueue(label: "org.signal.contacts.intersection")
    @objc
    var intersectionQueue: DispatchQueue { Self.intersectionQueue }

    private static func buildContactAvatarHash(contact: Contact) -> Data? {
        return autoreleasepool {
            guard let cnContactId: String = contact.cnContactId else {
                owsFailDebug("Missing cnContactId.")
                return nil
            }
            guard let contactAvatarData = Self.contactsManager.avatarData(forCNContactId: cnContactId) else {
                return nil
            }
            guard let contactAvatarHash = Cryptography.computeSHA256Digest(contactAvatarData) else {
                owsFailDebug("Could not digest contactAvatarData.")
                return nil
            }
            return contactAvatarHash
        }
    }

    private func buildSignalAccounts(
        for systemContacts: [Contact],
        transaction: SDSAnyReadTransaction
    ) -> [SignalAccount] {
        var signalAccounts = [SignalAccount]()
        var seenServiceIds = Set<ServiceId>()
        for contact in systemContacts {
            var signalRecipients = contact.discoverableRecipients(tx: transaction)
            // TODO: Confirm ordering.
            signalRecipients.sort { $0.address.compare($1.address) == .orderedAscending }
            let relatedAddresses = signalRecipients.map { $0.address }
            for signalRecipient in signalRecipients {
                guard let recipientServiceId = signalRecipient.aci ?? signalRecipient.pni else {
                    owsFailDebug("Can't be registered without a ServiceId.")
                    continue
                }
                guard seenServiceIds.insert(recipientServiceId).inserted else {
                    // We've already created a SignalAccount for this number.
                    continue
                }
                let multipleAccountLabelText = contact.uniquePhoneNumberLabel(
                    for: signalRecipient.address,
                    relatedAddresses: relatedAddresses
                )
                let contactAvatarHash = Self.buildContactAvatarHash(contact: contact)
                let signalAccount = SignalAccount(
                    contact: contact,
                    contactAvatarHash: contactAvatarHash,
                    multipleAccountLabelText: multipleAccountLabelText,
                    recipientPhoneNumber: signalRecipient.phoneNumber?.stringValue,
                    recipientServiceId: recipientServiceId
                )
                signalAccounts.append(signalAccount)
            }
        }
        return signalAccounts.stableSort()
    }

    fileprivate func buildSignalAccountsAndUpdatePersistedState(forFetchedSystemContacts localSystemContacts: [Contact]) {
        assertOnQueue(intersectionQueue)

        let (oldSignalAccounts, newSignalAccounts) = databaseStorage.read { transaction in
            let oldSignalAccounts = SignalAccount.anyFetchAll(transaction: transaction)
            let newSignalAccounts = buildSignalAccounts(for: localSystemContacts, transaction: transaction)
            return (oldSignalAccounts, newSignalAccounts)
        }
        let oldSignalAccountsMap: [SignalServiceAddress: SignalAccount] = Dictionary(
            oldSignalAccounts.lazy.map { ($0.recipientAddress, $0) },
            uniquingKeysWith: { _, new in new }
        )
        var newSignalAccountsMap = [SignalServiceAddress: SignalAccount]()

        var signalAccountChanges: [(remove: SignalAccount?, insert: SignalAccount?)] = []
        for newSignalAccount in newSignalAccounts {
            let address = newSignalAccount.recipientAddress

            // The user might have multiple entries in their address book with the same phone number.
            if newSignalAccountsMap[address] != nil {
                Logger.warn("Ignoring redundant signal account: \(address)")
                continue
            }

            let oldSignalAccountToKeep: SignalAccount?
            let oldSignalAccount = oldSignalAccountsMap[address]
            switch oldSignalAccount {
            case .none:
                oldSignalAccountToKeep = nil

            case .some(let oldSignalAccount) where oldSignalAccount.hasSameContent(newSignalAccount):
                // Same content, no need to update.
                oldSignalAccountToKeep = oldSignalAccount

            case .some:
                oldSignalAccountToKeep = nil
            }

            if let oldSignalAccount = oldSignalAccountToKeep {
                newSignalAccountsMap[address] = oldSignalAccount
            } else {
                newSignalAccountsMap[address] = newSignalAccount
                signalAccountChanges.append((oldSignalAccount, newSignalAccount))
            }
        }

        // Clean up orphans.
        for signalAccount in oldSignalAccounts {
            if newSignalAccountsMap[signalAccount.recipientAddress]?.uniqueId == signalAccount.uniqueId {
                // If the SignalAccount is going to be inserted or updated, it doesn't need
                // to be cleaned up.
                continue
            }
            // Clean up instances that have been replaced by another instance or are no
            // longer in the system contacts.
            signalAccountChanges.append((signalAccount, nil))
        }

        // Update cached SignalAccounts on disk
        databaseStorage.write { tx in
            func touchContactThread(for signalAccount: SignalAccount?) {
                guard
                    let signalAccount,
                    let contactThread = ContactThreadFinder()
                        .contactThread(for: signalAccount.recipientAddress, tx: tx),
                    contactThread.shouldThreadBeVisible
                else {
                    return
                }
                databaseStorage.touch(thread: contactThread, shouldReindex: true, transaction: tx)
            }

            for (signalAccountToRemove, signalAccountToInsert) in signalAccountChanges {
                let oldSignalAccount = signalAccountToRemove.flatMap {
                    SignalAccount.anyFetch(uniqueId: $0.uniqueId, transaction: tx)
                }
                let newSignalAccount = signalAccountToInsert

                oldSignalAccount?.anyRemove(transaction: tx)
                newSignalAccount?.anyInsert(transaction: tx)

                touchContactThread(for: newSignalAccount ?? oldSignalAccount)

                updatePhoneNumberVisibilityIfNeeded(
                    oldSignalAccount: oldSignalAccount,
                    newSignalAccount: newSignalAccount,
                    tx: tx.asV2Write
                )
            }

            Logger.info("Updated \(signalAccountChanges.count) SignalAccounts; now have \(newSignalAccountsMap.count) total")

            // Add system contacts to the profile whitelist immediately so that they do
            // not see the "message request" UI.
            profileManager.addUsers(
                toProfileWhitelist: Array(newSignalAccountsMap.keys),
                userProfileWriter: .systemContactsFetch,
                transaction: tx
            )

#if DEBUG
            let persistedAddresses = SignalAccount.anyFetchAll(transaction: tx).map {
                $0.recipientAddress
            }
            let persistedAddressSet = Set(persistedAddresses)
            owsAssertDebug(persistedAddresses.count == persistedAddressSet.count)
#endif
        }

        // Once we've persisted new SignalAccount state, we should let
        // StorageService know.
        updateStorageServiceForSystemContactsFetch(
            allSignalAccountsBeforeFetch: oldSignalAccountsMap,
            allSignalAccountsAfterFetch: newSignalAccountsMap
        )

        let didChangeAnySignalAccount = !signalAccountChanges.isEmpty
        DispatchQueue.main.async {
            // Post a notification if something changed or this is the first load since launch.
            let shouldNotify = didChangeAnySignalAccount || !self.hasLoadedSystemContacts
            self.hasLoadedSystemContacts = true
            self.swiftValues.systemContactsCache?.unsortedSignalAccounts.set(Array(newSignalAccountsMap.values))
            self.didUpdateSignalAccounts(shouldClearCache: false, shouldNotify: shouldNotify)
        }
    }

    /// Updates StorageService records for any Signal contacts associated with
    /// a system contact that has been added, removed, or modified in a
    /// relevant way. Has no effect when we are a linked device.
    private func updateStorageServiceForSystemContactsFetch(
        allSignalAccountsBeforeFetch: [SignalServiceAddress: SignalAccount],
        allSignalAccountsAfterFetch: [SignalServiceAddress: SignalAccount]
    ) {
        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isPrimaryDevice ?? false else {
            Logger.info("Skipping updating StorageService on contact change, not primary device!")
            return
        }

        /// Creates a mapping of addresses to system contacts, given an existing
        /// mapping of addresses to ``SignalAccount``s.
        func extractSystemContacts(
            accounts: [SignalServiceAddress: SignalAccount]
        ) -> (
            mapping: [SignalServiceAddress: Contact],
            addresses: Set<SignalServiceAddress>
        ) {
            let mapping = accounts.reduce(into: [SignalServiceAddress: Contact]()) { partialResult, kv in
                let (address, account) = kv

                guard let contact = account.contact else {
                    return
                }

                partialResult[address] = contact
            }

            return (mapping: mapping, addresses: Set(mapping.keys))
        }

        let systemContactsBeforeFetch = extractSystemContacts(accounts: allSignalAccountsBeforeFetch)
        let systemContactsAfterFetch = extractSystemContacts(accounts: allSignalAccountsAfterFetch)

        var addressesToUpdateInStorageService: Set<SignalServiceAddress> = []

        // System contacts that are not present both before and after the fetch
        // were either removed or added. In both cases, we should update their
        // StorageService records.
        //
        // Note that just because a system contact was removed does *not* mean
        // we should remove the ContactRecord from StorageService. Rather, we
        // want to update the ContactRecord to reflect the removed system
        // contact details.
        let addedOrRemovedSystemContactAddresses = systemContactsAfterFetch.addresses
            .symmetricDifference(systemContactsBeforeFetch.addresses)

        addressesToUpdateInStorageService.formUnion(addedOrRemovedSystemContactAddresses)

        // System contacts present both before and after may have been updated
        // in a StorageService-relevant way. If so, we should let StorageService
        // know.
        let possiblyUpdatedSystemContactAddresses = systemContactsAfterFetch.addresses
            .intersection(systemContactsBeforeFetch.addresses)

        for address in possiblyUpdatedSystemContactAddresses {
            let contactBefore = systemContactsBeforeFetch.mapping[address]!
            let contactAfter = systemContactsAfterFetch.mapping[address]!

            if !contactBefore.namesAreEqual(toOther: contactAfter) {
                addressesToUpdateInStorageService.insert(address)
            }
        }

        storageServiceManager.recordPendingUpdates(updatedAddresses: Array(addressesToUpdateInStorageService))
    }

    private func updatePhoneNumberVisibilityIfNeeded(
        oldSignalAccount: SignalAccount?,
        newSignalAccount: SignalAccount?,
        tx: DBWriteTransaction
    ) {
        let aciToUpdate = SignalAccount.aciForPhoneNumberVisibilityUpdate(
            oldAccount: oldSignalAccount,
            newAccount: newSignalAccount
        )
        guard let aciToUpdate else {
            return
        }
        let recipientDatabaseTable = DependenciesBridge.shared.recipientDatabaseTable
        let recipient = recipientDatabaseTable.fetchRecipient(serviceId: aciToUpdate, transaction: tx)
        guard let recipient else {
            return
        }
        // Tell the cache to refresh its state for this recipient. It will check
        // whether or not the number should be visible based on this state and the
        // state of system contacts.
        signalServiceAddressCache.updateRecipient(recipient, tx: tx)
    }

    func didUpdateSignalAccounts(transaction: SDSAnyWriteTransaction) {
        transaction.addTransactionFinalizationBlock(forKey: "OWSContactsManager.didUpdateSignalAccounts") { _ in
            self.didUpdateSignalAccounts(shouldClearCache: true, shouldNotify: true)
        }
    }

    private func didUpdateSignalAccounts(shouldClearCache: Bool, shouldNotify: Bool) {
        if shouldClearCache {
            swiftValues.systemContactsCache?.unsortedSignalAccounts.set(nil)
        }
        if shouldNotify {
            NotificationCenter.default.postNotificationNameAsync(.OWSContactsManagerSignalAccountsDidChange, object: nil)
        }
    }
}

// MARK: - Intersection

extension OWSContactsManager {
    private enum Constants {
        static let nextFullIntersectionDate = "OWSContactsManagerKeyNextFullIntersectionDate2"
        static let lastKnownContactPhoneNumbers = "OWSContactsManagerKeyLastKnownContactPhoneNumbers"
        static let didIntersectAddressBook = "didIntersectAddressBook"
    }

    @objc
    func updateContacts(_ addressBookContacts: [Contact]?, isUserRequested: Bool) {
        intersectionQueue.async { self._updateContacts(addressBookContacts, isUserRequested: isUserRequested) }
    }

    private func _updateContacts(_ addressBookContacts: [Contact]?, isUserRequested: Bool) {
        let (localNumber, contactsMaps) = databaseStorage.write { tx in
            let localNumber = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx.asV2Read)?.phoneNumber
            let contactsMaps = ContactsMaps.build(contacts: addressBookContacts ?? [], localNumber: localNumber)
            setContactsMaps(contactsMaps, localNumber: localNumber, transaction: tx)
            return (localNumber, contactsMaps)
        }
        cnContactCache.removeAllObjects()

        NotificationCenter.default.postNotificationNameAsync(.OWSContactsManagerContactsDidChange, object: nil)

        intersectContacts(
            addressBookContacts, localNumber: localNumber, isUserRequested: isUserRequested
        ).done(on: intersectionQueue) {
            self.buildSignalAccountsAndUpdatePersistedState(forFetchedSystemContacts: contactsMaps.allContacts)
        }.catch(on: DispatchQueue.global()) { error in
            owsFailDebug("Couldn't intersect contacts: \(error)")
        }
    }

    private func fetchPriorIntersectionPhoneNumbers(tx: SDSAnyReadTransaction) -> Set<String>? {
        keyValueStore.getObject(forKey: Constants.lastKnownContactPhoneNumbers, transaction: tx) as? Set<String>
    }

    private func setPriorIntersectionPhoneNumbers(_ phoneNumbers: Set<String>, tx: SDSAnyWriteTransaction) {
        keyValueStore.setObject(phoneNumbers, key: Constants.lastKnownContactPhoneNumbers, transaction: tx)
    }

    private enum IntersectionMode {
        /// It's time for the regularly-scheduled full intersection.
        case fullIntersection

        /// It's not time for the regularly-scheduled full intersection. Only check
        /// new phone numbers.
        case deltaIntersection(priorPhoneNumbers: Set<String>)
    }

    private func fetchIntersectionMode(isUserRequested: Bool, tx: SDSAnyReadTransaction) -> IntersectionMode {
        if isUserRequested {
            return .fullIntersection
        }
        let nextFullIntersectionDate = keyValueStore.getDate(Constants.nextFullIntersectionDate, transaction: tx)
        guard let nextFullIntersectionDate, nextFullIntersectionDate.isAfterNow else {
            return .fullIntersection
        }
        guard let priorPhoneNumbers = fetchPriorIntersectionPhoneNumbers(tx: tx) else {
            // We don't know the prior phone numbers, so do a `.fullIntersection`.
            return .fullIntersection
        }
        return .deltaIntersection(priorPhoneNumbers: priorPhoneNumbers)
    }

    private func intersectionPhoneNumbers(for contacts: [Contact]) -> Set<String> {
        var result = Set<String>()
        for contact in contacts {
            result.formUnion(contact.e164sForIntersection)
        }
        return result
    }

    private func intersectContacts(
        _ addressBookContacts: [Contact]?,
        localNumber: String?,
        isUserRequested: Bool
    ) -> Promise<Void> {
        let (intersectionMode, signalRecipientPhoneNumbers) = databaseStorage.read { tx in
            let intersectionMode = fetchIntersectionMode(isUserRequested: isUserRequested, tx: tx)
            let signalRecipientPhoneNumbers = SignalRecipient.fetchAllPhoneNumbers(tx: tx)
            return (intersectionMode, signalRecipientPhoneNumbers)
        }
        let addressBookPhoneNumbers = addressBookContacts.map { intersectionPhoneNumbers(for: $0) }

        var phoneNumbersToIntersect = Set(signalRecipientPhoneNumbers.keys)
        if let addressBookPhoneNumbers {
            phoneNumbersToIntersect.formUnion(addressBookPhoneNumbers)
        }
        if case .deltaIntersection(let priorPhoneNumbers) = intersectionMode {
            phoneNumbersToIntersect.subtract(priorPhoneNumbers)
        }
        if let localNumber {
            phoneNumbersToIntersect.remove(localNumber)
        }

        switch intersectionMode {
        case .fullIntersection:
            Logger.info("Performing full intersection for \(phoneNumbersToIntersect.count) phone numbers.")
        case .deltaIntersection:
            Logger.info("Performing delta intersection for \(phoneNumbersToIntersect.count) phone numbers.")
        }

        let intersectionPromise = intersectContacts(phoneNumbersToIntersect, retryDelaySeconds: 1)
        return intersectionPromise.done(on: intersectionQueue) { intersectedRecipients in
            Self.databaseStorage.write { tx in
                self.migrateDidIntersectAddressBookIfNeeded(tx: tx)
                self.postJoinNotificationsIfNeeded(
                    addressBookPhoneNumbers: addressBookPhoneNumbers,
                    phoneNumberRegistrationStatus: signalRecipientPhoneNumbers,
                    intersectedRecipients: intersectedRecipients,
                    tx: tx
                )
                self.unhideRecipientsIfNeeded(
                    addressBookPhoneNumbers: addressBookPhoneNumbers,
                    tx: tx.asV2Write
                )
                self.didFinishIntersection(mode: intersectionMode, phoneNumbers: phoneNumbersToIntersect, tx: tx)
            }
        }
    }

    private func migrateDidIntersectAddressBookIfNeeded(tx: SDSAnyWriteTransaction) {
        // This is carefully-constructed migration code that can be deleted in the
        // future without requiring additional cleanup logic. If we don't know
        // whether or not the address book has ever been intersected (ie we're
        // running this logic for the first time in a version that includes this
        // new flag), we set the flag based on whether or not we've ever performed
        // a full intersection (ie whether or not we've intersected the address
        // book). (Once we delete this logic, users who haven't run it will
        // potentially miss one round of "User Joined Signal" notifications, but
        // that's a reasonable fallback.)
        //
        // TODO: Delete this migration method on/after Jan 31, 2024.
        if keyValueStore.hasValue(forKey: Constants.didIntersectAddressBook, transaction: tx) {
            return
        }
        keyValueStore.setBool(
            keyValueStore.hasValue(forKey: Constants.nextFullIntersectionDate, transaction: tx),
            key: Constants.didIntersectAddressBook,
            transaction: tx
        )
    }

    private func postJoinNotificationsIfNeeded(
        addressBookPhoneNumbers: Set<String>?,
        phoneNumberRegistrationStatus: [String: Bool],
        intersectedRecipients: some Sequence<SignalRecipient>,
        tx: SDSAnyWriteTransaction
    ) {
        guard let addressBookPhoneNumbers else {
            return
        }
        let didIntersectAtLeastOnce = keyValueStore.getBool(Constants.didIntersectAddressBook, defaultValue: false, transaction: tx)
        guard didIntersectAtLeastOnce else {
            // This is the first address book intersection. Don't post notifications,
            // but mark the flag so that we post notifications next time.
            keyValueStore.setBool(true, key: Constants.didIntersectAddressBook, transaction: tx)
            return
        }
        guard Self.preferences.shouldNotifyOfNewAccounts(transaction: tx) else {
            return
        }
        for signalRecipient in intersectedRecipients {
            guard let phoneNumber = signalRecipient.phoneNumber, phoneNumber.isDiscoverable else {
                continue  // Can't happen.
            }
            guard addressBookPhoneNumbers.contains(phoneNumber.stringValue) else {
                continue  // Not in the address book -- no notification.
            }
            guard phoneNumberRegistrationStatus[phoneNumber.stringValue] != true else {
                continue  // They were already registered -- no notification.
            }
            NewAccountDiscovery.postNotification(for: signalRecipient, tx: tx)
        }
    }

    /// We cannot hide a contact that is in our address book.
    /// As a result, when a contact that was hidden is added to the address book,
    /// we must unhide them.
    private func unhideRecipientsIfNeeded(
        addressBookPhoneNumbers: Set<String>?,
        tx: DBWriteTransaction
    ) {
        guard let addressBookPhoneNumbers else {
            return
        }
        let recipientHidingManager = DependenciesBridge.shared.recipientHidingManager
        for hiddenRecipient in recipientHidingManager.hiddenRecipients(tx: tx) {
            guard let phoneNumber = hiddenRecipient.phoneNumber else {
                continue // We can't unhide because of the address book w/o a phone number.
            }
            guard phoneNumber.isDiscoverable else {
                continue // Not discoverable -- no unhiding.
            }
            guard addressBookPhoneNumbers.contains(phoneNumber.stringValue) else {
                continue  // Not in the address book -- no unhiding.
            }
            DependenciesBridge.shared.recipientHidingManager.removeHiddenRecipient(
                hiddenRecipient,
                wasLocallyInitiated: true,
                tx: tx
            )
        }
    }

    private func didFinishIntersection(
        mode intersectionMode: IntersectionMode,
        phoneNumbers: Set<String>,
        tx: SDSAnyWriteTransaction
    ) {
        switch intersectionMode {
        case .fullIntersection:
            setPriorIntersectionPhoneNumbers(phoneNumbers, tx: tx)
            let nextFullIntersectionDate = Date(timeIntervalSinceNow: RemoteConfig.cdsSyncInterval)
            keyValueStore.setDate(nextFullIntersectionDate, key: Constants.nextFullIntersectionDate, transaction: tx)

        case .deltaIntersection:
            // If a user has a "flaky" address book (perhaps it's a network-linked
            // directory that goes in and out of existence), we could get thrashing
            // between what the last known set is, causing us to re-intersect contacts
            // many times within the debounce interval. So while we're doing
            // incremental intersections, we *accumulate*, rather than replace, the set
            // of recently intersected contacts.
            let priorPhoneNumbers = fetchPriorIntersectionPhoneNumbers(tx: tx) ?? []
            setPriorIntersectionPhoneNumbers(priorPhoneNumbers.union(phoneNumbers), tx: tx)
        }
    }

    private func intersectContacts(
        _ phoneNumbers: Set<String>,
        retryDelaySeconds: TimeInterval
    ) -> Promise<Set<SignalRecipient>> {
        owsAssertDebug(retryDelaySeconds > 0)

        if phoneNumbers.isEmpty {
            return .value([])
        }
        return contactDiscoveryManager.lookUp(
            phoneNumbers: phoneNumbers,
            mode: .contactIntersection
        ).recover(on: DispatchQueue.global()) { (error) -> Promise<Set<SignalRecipient>> in
            var retryAfter: TimeInterval = retryDelaySeconds

            if let cdsError = error as? ContactDiscoveryError {
                guard cdsError.code != ContactDiscoveryError.Kind.rateLimit.rawValue else {
                    Logger.error("Contact intersection hit rate limit with error: \(error)")
                    return Promise(error: error)
                }
                guard cdsError.retrySuggested else {
                    Logger.error("Contact intersection error suggests not to retry. Aborting without rescheduling.")
                    return Promise(error: error)
                }
                if let retryAfterDate = cdsError.retryAfterDate {
                    retryAfter = max(retryAfter, retryAfterDate.timeIntervalSinceNow)
                }
            }

            // TODO: Abort if another contact intersection succeeds in the meantime.
            Logger.warn("Contact intersection failed with error: \(error). Rescheduling.")
            return Guarantee.after(seconds: retryAfter).then(on: DispatchQueue.global()) {
                self.intersectContacts(phoneNumbers, retryDelaySeconds: retryDelaySeconds * 2)
            }
        }
    }
}

// MARK: -

public extension OWSContactsManager {

    private static let unknownAddressFetchDateMap = AtomicDictionary<Aci, Date>()

    @objc(fetchProfileForUnknownAddress:)
    func fetchProfile(forUnknownAddress address: SignalServiceAddress) {
        // We only consider ACIs b/c PNIs will never give us a name other than "Unknown".
        guard let aci = address.serviceId as? Aci else {
            return
        }
        let minFetchInterval = kMinuteInterval * 30
        if
            let lastFetchDate = Self.unknownAddressFetchDateMap[aci],
            abs(lastFetchDate.timeIntervalSinceNow) < minFetchInterval
        {
            return
        }

        Self.unknownAddressFetchDateMap[aci] = Date()

        bulkProfileFetch.fetchProfile(address: address)
    }
}

// MARK: -

public extension Array where Element == SignalAccount {
    func stableSort() -> [SignalAccount] {
        // Use an arbitrary sort but ensure the ordering is stable.
        self.sorted { (left, right) in
            left.recipientAddress.sortKey < right.recipientAddress.sortKey
        }
    }
}

// MARK: System Contacts

private class SystemContactsCache {
    let unsortedSignalAccounts = AtomicOptional<[SignalAccount]>(nil)
    let contactsMaps = AtomicOptional<ContactsMaps>(nil)
}

extension OWSContactsManager {
    @objc
    func setUpSystemContacts() {
        updateSystemContactsDataProvider()
        registerForRegistrationStateNotification()
        if CurrentAppContext().isMainApp {
            warmSystemContactsCache()
        }
    }

    public func setIsPrimaryDevice() {
        updateSystemContactsDataProvider(forcePrimary: true)
    }

    private func registerForRegistrationStateNotification() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )
    }

    @objc
    private func registrationStateDidChange() {
        updateSystemContactsDataProvider()
    }

    private func updateSystemContactsDataProvider(forcePrimary: Bool = false) {
        let tsRegistrationState = DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction
        let dataProvider: SystemContactsDataProvider?
        if forcePrimary {
            dataProvider = PrimaryDeviceSystemContactsDataProvider()
        } else if !tsRegistrationState.wasEverRegistered {
            dataProvider = nil
        } else if tsRegistrationState.isPrimaryDevice ?? true {
            dataProvider = PrimaryDeviceSystemContactsDataProvider()
        } else {
            dataProvider = LinkedDeviceSystemContactsDataProvider()
        }
        swiftValues.systemContactsDataProvider.set(dataProvider)
    }

    private func warmSystemContactsCache() {
        let systemContactsCache = SystemContactsCache()
        swiftValues.systemContactsCache = systemContactsCache

        databaseStorage.read {
            var phoneNumberCount = 0
            if let dataProvider = swiftValues.systemContactsDataProvider.get() {
                let contactsMaps = buildContactsMaps(using: dataProvider, transaction: $0)
                systemContactsCache.contactsMaps.set(contactsMaps)
                phoneNumberCount = contactsMaps.phoneNumberToContactMap.count
            }

            let unsortedSignalAccounts = fetchUnsortedSignalAccounts(transaction: $0)
            systemContactsCache.unsortedSignalAccounts.set(unsortedSignalAccounts)
            let signalAccountCount = unsortedSignalAccounts.count

            Logger.info("There are \(phoneNumberCount) phone numbers and \(signalAccountCount) SignalAccounts.")
        }
    }

    @objc
    public func contact(forPhoneNumber phoneNumber: String, transaction: SDSAnyReadTransaction) -> Contact? {
        if let cachedValue = swiftValues.systemContactsCache?.contactsMaps.get() {
            return cachedValue.phoneNumberToContactMap[phoneNumber]
        }
        guard let dataProvider = swiftValues.systemContactsDataProvider.get() else {
            owsFailDebug("Can't access contacts until registration is finished.")
            return nil
        }
        return dataProvider.fetchSystemContact(for: phoneNumber, transaction: transaction)
    }

    private func buildContactsMaps(
        using dataProvider: SystemContactsDataProvider,
        transaction: SDSAnyReadTransaction
    ) -> ContactsMaps {
        let systemContacts = dataProvider.fetchAllSystemContacts(transaction: transaction)
        let localNumber = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: transaction.asV2Read)?.phoneNumber
        return ContactsMaps.build(contacts: systemContacts, localNumber: localNumber)
    }

    @objc
    func setContactsMaps(_ contactsMaps: ContactsMaps, localNumber: String?, transaction: SDSAnyWriteTransaction) {
        guard let dataProvider = swiftValues.primaryDeviceSystemContactsDataProvider else {
            return owsFailDebug("Can't modify contacts maps on linked devices.")
        }
        let oldContactsMaps = swiftValues.systemContactsCache?.contactsMaps.swap(contactsMaps)
        dataProvider.setContactsMaps(
            contactsMaps,
            oldContactsMaps: { oldContactsMaps ?? buildContactsMaps(using: dataProvider, transaction: transaction) },
            localNumber: localNumber,
            transaction: transaction
        )
    }

    private func fetchUnsortedSignalAccounts(transaction: SDSAnyReadTransaction) -> [SignalAccount] {
        SignalAccount.anyFetchAll(transaction: transaction)
    }

    @objc
    public func unsortedSignalAccounts(transaction: SDSAnyReadTransaction) -> [SignalAccount] {
        if let cachedValue = swiftValues.systemContactsCache?.unsortedSignalAccounts.get() {
            return cachedValue
        }
        let uncachedValue = fetchUnsortedSignalAccounts(transaction: transaction)
        swiftValues.systemContactsCache?.unsortedSignalAccounts.set(uncachedValue)
        return uncachedValue
    }
}

// MARK: - Display Names

extension OWSContactsManager {
    private func displayNamesRefinery(
        for addresses: [SignalServiceAddress],
        transaction: SDSAnyReadTransaction
    ) -> Refinery<SignalServiceAddress, String> {
        return .init(addresses).refine { addresses in
            // Prefer a saved name from system contacts, if available.
            systemContactNames(for: addresses, tx: transaction)
        }.refine { addresses in
            profileManager.fullNames(for: Array(addresses), tx: transaction)
        }.refine { addresses in
            phoneNumbers(for: Array(addresses)).lazy.map { $0?.nilIfEmpty }
        }.refine { addresses -> [String?] in
            swiftValues.usernameLookupManager.fetchUsernames(
                forAddresses: addresses,
                transaction: transaction.asV2Read
            )
        }.refine { addresses in
            return addresses.lazy.map {
                self.fetchProfile(forUnknownAddress: $0)
                return Self.unknownUserLabel
            }
        }
    }

    private func displayNamesOptionalRefinery(
        for addresses: [SignalServiceAddress],
        transaction: SDSAnyReadTransaction
    ) -> Refinery<SignalServiceAddress, String?> {
        return .init(addresses).refine { addresses -> [String??] in
            // Prefer a saved name from system contacts, if available.
            systemContactNames(for: addresses, tx: transaction)
        }.refine { addresses -> [String??] in
            profileManager.fullNames(for: Array(addresses), tx: transaction)
        }.refine { addresses -> [String??] in
            phoneNumbers(for: Array(addresses)).lazy.map { $0?.nilIfEmpty }
        }.refine { addresses -> [String??] in
            swiftValues.usernameLookupManager.fetchUsernames(
                forAddresses: addresses,
                transaction: transaction.asV2Read
            )
        }.refine { addresses -> [String??] in
            return addresses.lazy.map {
                self.fetchProfile(forUnknownAddress: $0)
                return nil
            }
        }
    }

    public func displayNamesByAddress(
        for addresses: [SignalServiceAddress],
        transaction: SDSAnyReadTransaction
    ) -> [SignalServiceAddress: String] {
        Dictionary(displayNamesRefinery(for: addresses, transaction: transaction))
    }

    @objc(objc_displayNamesForAddresses:transaction:)
    func displayNames(for addresses: [SignalServiceAddress], transaction: SDSAnyReadTransaction) -> [String] {
        displayNamesRefinery(for: addresses, transaction: transaction).values.map { $0! }
    }

    @objc
    func _nonUnknownDisplayName(for address: SignalServiceAddress, transaction: SDSAnyReadTransaction) -> String? {
        return displayNamesOptionalRefinery(for: [address], transaction: transaction).values[0]!
    }

    func phoneNumbers(for addresses: [SignalServiceAddress]) -> [String?] {
        return addresses.map { E164($0.phoneNumber)?.stringValue }
    }

    func fetchSignalAccounts(
        for addresses: some Sequence<SignalServiceAddress>,
        transaction: SDSAnyReadTransaction
    ) -> [SignalAccount?] {
        let phoneNumbers = addresses.map { $0.phoneNumber }
        var compactedResult = modelReadCaches.signalAccountReadCache.getSignalAccounts(
            phoneNumbers: phoneNumbers.compacted(),
            transaction: transaction
        ).makeIterator()
        return phoneNumbers.map { $0 != nil ? compactedResult.next()! : nil }
    }

    @objc
    func _systemContactName(for address: SignalServiceAddress, tx: SDSAnyReadTransaction) -> String? {
        return systemContactNames(for: AnySequence([address]), tx: tx)[0]
    }

    func systemContactNames(for addresses: AnySequence<SignalServiceAddress>, tx: SDSAnyReadTransaction) -> [String?] {
        return fetchSignalAccounts(for: addresses, transaction: tx).map { $0?.fullName }
    }

    @objc
    public static var unknownUserLabel: String {
        return OWSLocalizedString("UNKNOWN_USER", comment: "Label indicating an unknown user.")
    }
}

private extension SignalAccount {
    var fullName: String? {
        // Name may be either the nickname or the full name of the contact
        guard let fullName = contactPreferredDisplayName() else {
            return nil
        }
        guard let label = multipleAccountLabelText.nilIfEmpty else {
            return fullName
        }
        return "\(fullName) (\(label))"
    }
}

// MARK: - ContactsManagerProtocol

extension ContactsManagerProtocol {
    public func nameForAddress(_ address: SignalServiceAddress,
                               localUserDisplayMode: LocalUserDisplayMode,
                               short: Bool,
                               transaction: SDSAnyReadTransaction) -> NSAttributedString {
        let name: String
        if address.isLocalAddress {
            switch localUserDisplayMode {
            case .noteToSelf:
                name = MessageStrings.noteToSelf
            case .asLocalUser:
                name = CommonStrings.you
            case .asUser:
                if short {
                    name = shortDisplayName(for: address, transaction: transaction)
                } else {
                    name = displayName(for: address, transaction: transaction)
                }
            }
        } else {
            if short {
                name = shortDisplayName(for: address, transaction: transaction)
            } else {
                name = displayName(for: address, transaction: transaction)
            }
        }
        return name.asAttributedString
    }

    public func displayName(for thread: TSThread, transaction: SDSAnyReadTransaction) -> String {
        if thread.isNoteToSelf {
            return MessageStrings.noteToSelf
        }
        switch thread {
        case let thread as TSContactThread:
            return displayName(for: thread.contactAddress, transaction: transaction)
        case let thread as TSGroupThread:
            return thread.groupNameOrDefault
        default:
            owsFailDebug("Unexpected thread type: \(type(of: thread))")
            return ""
        }
    }

    public func sortSignalServiceAddresses(
        _ addresses: some Sequence<SignalServiceAddress>,
        transaction: SDSAnyReadTransaction
    ) -> [SignalServiceAddress] {
        return sortedSortableAddresses(for: addresses, tx: transaction).map { $0.address }
    }

    public func sortedSortableAddresses(
        for addresses: some Sequence<SignalServiceAddress>,
        tx: SDSAnyReadTransaction
    ) -> [SortableAddress] {
        let sortableAddresses = addresses.map { address in
            return SortableAddress(
                address: address,
                comparableName: comparableName(for: address, transaction: tx)
            )
        }
        return sortableAddresses.sorted()
    }

    public func sortedNonUnknownSortableAddresses(
        for addresses: some Sequence<SignalServiceAddress>,
        tx: SDSAnyReadTransaction
    ) -> [SortableAddress] {
        let sortableAddresses = addresses.compactMap { address -> SortableAddress? in
            guard let comparableName = comparableNonUnknownName(for: address, transaction: tx) else {
                return nil
            }
            return SortableAddress(
                address: address,
                comparableName: comparableName
            )
        }
        return sortableAddresses.sorted()
    }
}
