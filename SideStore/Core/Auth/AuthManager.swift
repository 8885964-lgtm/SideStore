//
//  AuthManager.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign
import CoreData

public final class AuthManager: @unchecked Sendable {
    public static let shared = AuthManager()
    
    private var portalProxy: DeveloperPortalProxyWithAuth {
        DeveloperPortalProxy.shared as! DeveloperPortalProxyWithAuth
    }
    
    private init() {}
    
    private let cacheLock = NSLock()
    private var cachedTeam: ALTTeam?
    private var cachedSession: ALTAppleAPISession?
    // Bumped whenever the cached team is replaced, so a slower lookup can't overwrite a newer team.
    private var teamGeneration = 0
    
    private var team: ALTTeam? {
        get { self.cacheLock.withLock { self.cachedTeam } }
        set {
            self.cacheLock.withLock {
                self.cachedTeam = newValue
                self.teamGeneration += 1
            }
        }
    }
    
    private var session: ALTAppleAPISession? {
        get { self.cacheLock.withLock { self.cachedSession } }
        set { self.cacheLock.withLock { self.cachedSession = newValue } }
    }

    public var isAuthenticated: Bool {
        let hasEmail = Keychain.shared.appleIDEmailAddress != nil
        let hasPassword = Keychain.shared.appleIDPassword != nil
        let hasToken = Keychain.shared.appleIDXcodeToken != nil
        return hasEmail && (hasPassword || hasToken)
    }
    
    public var currentAppleID: String? {
        get { Keychain.shared.appleIDEmailAddress }
        set { Keychain.shared.appleIDEmailAddress = newValue }
    }
    
    public var password: String? {
        get { Keychain.shared.appleIDPassword }
        set { Keychain.shared.appleIDPassword = newValue }
    }
    
    public var adsid: String? {
        get { Keychain.shared.appleIDAdsid }
        set { Keychain.shared.appleIDAdsid = newValue }
    }
    
    public var xcodeToken: String? {
        get { Keychain.shared.appleIDXcodeToken }
        set { Keychain.shared.appleIDXcodeToken = newValue }
    }
    
    public var hasStoredPassword: Bool {
        return Keychain.shared.appleIDPassword != nil
    }
    
    public var hasStoredXcodeToken: Bool {
        return Keychain.shared.appleIDXcodeToken != nil
    }
    
    public func signOut(
        keepCertificate: Bool = false,
        keepAnisetteData: Bool = true,
        keepAnisetteHeaders: Bool = true,
        keepSideSignHeaders: Bool = true,
        promoteRemaining: Bool = true
    ) async {
        // A reset anisette identity needs fresh sign-ins, so no other stored Apple ID is signed in in its place.
        let promotes = promoteRemaining && keepAnisetteData
        
        if let holding = AccountSessionGate.holding {
            await self.signOutCurrent(
                keepCertificate: keepCertificate,
                keepAnisetteData: keepAnisetteData,
                keepAnisetteHeaders: keepAnisetteHeaders,
                keepSideSignHeaders: keepSideSignHeaders,
                promoteRemaining: promotes && holding == .exclusive && !Keychain.shared.isAccountOverrideActive
            )
            return
        }
        
        let access: AccountSessionGate.Access = (promotes && AppleAccountStore.shared.storedAppleIDs().count > 1) ? .exclusive : .credentials
        await AccountSessionGate.shared.withAccess(access) {
            await self.signOutCurrent(
                keepCertificate: keepCertificate,
                keepAnisetteData: keepAnisetteData,
                keepAnisetteHeaders: keepAnisetteHeaders,
                keepSideSignHeaders: keepSideSignHeaders,
                promoteRemaining: access == .exclusive
            )
        }
    }

    private func signOutCurrent(
        keepCertificate: Bool,
        keepAnisetteData: Bool,
        keepAnisetteHeaders: Bool,
        keepSideSignHeaders: Bool,
        promoteRemaining: Bool
    ) async {
        if let removedAppleID = self.currentAppleID {
            AppleAccountStore.shared.remove(appleID: removedAppleID)
        }
        self.session = nil
        self.team = nil
        if !keepCertificate {
            debugLog("[AuthManager] Clearing signing certificate in cert manager and keychain.")
            CertificateManager.shared.clearActiveCertificate()
            debugLog("[AuthManager] Cleared signing certificate in cert manager and keychain.")

        } else {
            debugLog("[AuthManager] Preserved signing certificate in cert manager and keychain.")
        }
        debugLog("[AuthManager] Clearing account and team info in database.")
        await DatabaseManager.shared.deactivateActiveAccountAndTeam()
        debugLog("[AuthManager] Cleared account and team info in database.")

        debugLog("[AuthManager] Clearing sign-in info from keychain.")
        Keychain.shared.clearSignInInfo(keepAnisetteData: keepAnisetteData)
        debugLog("[AuthManager] Cleared sign-in info from keychain.")

        if !keepAnisetteHeaders {
            debugLog("[AuthManager] Resetting Anisette header customizations to defaults.")
            AnisetteConfigManager.shared.resetToDefaults()
        }

        if !keepSideSignHeaders {
            debugLog("[AuthManager] Resetting SideSign header customizations to defaults.")
            SideSignConfigManager.shared.resetToDefaults()
        }

        AnisetteDataManager.shared.clearCache()

        if promoteRemaining, let next = AppleAccountStore.shared.storedAppleIDs().first {
            await AccountSessionGate.shared.promote(next)
        }
    }
    
    @discardableResult
    public func getAuthenticatedSession() async throws -> ALTAppleAPISession {
        // Read once so the session is built from the same Apple ID its coalescing key names.
        let storedAdsid = self.adsid
        let storedXcodeToken = self.xcodeToken
        return try await TaskChainCoalescer.shared.coalesce(key: "apple_auth_session_\(storedAdsid ?? "")") {
            guard let adsid = storedAdsid,                          // directory services id
                  let xcodeToken = storedXcodeToken else            // xcode token
            {
                debugLog("[AuthManager] No stored tokens found.")
                throw OperationError.notAuthenticated
            }
            let anisetteData = try await AnisetteProvider.fetch()   // one time pass
            let xcodeVersion = await AnisetteConfigManager.shared.resolvedXcodeVersion()
            
            let session = ALTAppleAPISession(
                dsid: adsid,
                authToken: xcodeToken,
                anisetteData: anisetteData,
                xcodeVersion: xcodeVersion
            )
            self.session = session
            return session
        }
    }

    func invalidateCachedSession() {
        self.session = nil
        self.team = nil
    }

    /// Serves `team` to pipeline work while another stored Apple ID is signed in for one batch.
    func overrideCachedTeam(_ team: ALTTeam) {
        self.session = nil
        self.team = team
    }

    /// The free-account active app limit for a signed-in team of `teamType`, as set at sign-in.
    public func activeAppsLimit(for teamType: ALTTeamType) -> Int? {
        guard teamType == .free else { return nil }
        let isSparseRestorePatched = ProcessInfo().sparseRestorePatched
        let isAppLimitDisabled = UserDefaults.standard.isAppLimitDisabled
        guard (!isAppLimitDisabled && isSparseRestorePatched) ||
              (isAppLimitDisabled && !isSparseRestorePatched) else { return nil }
        return InstalledApp.freeAccountActiveAppsLimit
    }

    public func applyActiveAppsLimit(for teamType: ALTTeamType) {
        UserDefaults.standard.activeAppsLimit = self.activeAppsLimit(for: teamType)
    }

    public func getAuthenticatedTeam() async throws -> ALTTeam {
        let (cachedTeam, generation) = self.cacheLock.withLock { (self.cachedTeam, self.teamGeneration) }
        if let cachedTeam {
            return cachedTeam
        }
        
        let team = try await self.resolveActiveTeam()
        self.cacheLock.withLock {
            if self.teamGeneration == generation {
                self.cachedTeam = team
            }
        }
        return team
    }

    private func resolveActiveTeam() async throws -> ALTTeam {
        try await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            guard let dbTeam = DatabaseManager.shared.activeTeam(in: context) else {
                throw OperationError.notAuthenticated
            }
            return ALTTeam(identifier: dbTeam.identifier, name: dbTeam.name, type: dbTeam.type)
        }
    }
    
    @discardableResult
    func signIn(
        presentingViewController: UIViewController? = nil,
        skipDeviceRegistration: Bool = false,
        skipCertificateProvisioning: Bool = false,
        skipResign: Bool = false,
        skipHowTos: Bool = false
    ) async throws -> SignInResult {
        return try await AccountSessionGate.shared.withAccess(.credentials) {
            AppleAccountStore.shared.captureCurrentCredentials()
            do {
                let result = try await self.performSignIn(
                    presentingViewController: presentingViewController,
                    skipDeviceRegistration: skipDeviceRegistration,
                    skipCertificateProvisioning: skipCertificateProvisioning,
                    skipResign: skipResign,
                    skipHowTos: skipHowTos
                )
                AppleAccountStore.shared.captureCurrentCredentials()
                return result
            } catch {
                if self.currentAppleID != nil {
                    AppleAccountStore.shared.captureCurrentCredentials()
                }
                throw error
            }
        }
    }

    /// Signs in another Apple ID and makes it the signed-in one. The current Apple ID stays stored,
    /// and is signed in again if this fails or is cancelled.
    @discardableResult
    func addAccount(presentingViewController: UIViewController?) async throws -> SignInResult {
        return try await AccountSessionGate.shared.addAccount {
            try await self.performSignIn(
                presentingViewController: presentingViewController,
                skipDeviceRegistration: false,
                skipCertificateProvisioning: false,
                // SideStore stays signed by the Apple ID that installed it.
                skipResign: true,
                skipHowTos: false
            )
        }
    }

    /// Forgets a stored Apple ID. Removing the signed-in one signs out and signs in the next stored Apple ID.
    func removeAccount(_ appleID: String) async {
        if let current = AppleAccountStore.shared.activeAppleID, current.caseInsensitiveCompare(appleID) == .orderedSame {
            await self.signOut()
            return
        }
        await AccountSessionGate.shared.withAccess(.credentials) {
            AppleAccountStore.shared.remove(appleID: appleID)
        }
    }

    private func performSignIn(
        presentingViewController: UIViewController?,
        skipDeviceRegistration: Bool,
        skipCertificateProvisioning: Bool,
        skipResign: Bool,
        skipHowTos: Bool
    ) async throws -> SignInResult {
        let dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let signInFlowHandler = SignInFlowHandler(presentingViewController: presentingViewController)
        let context = StandaloneOperationContext(
            steps: .signIn,
            dbBackgroundContext: dbBackgroundContext
        )
        
        let signInOperation = try SignInOperation(
            context: context,
            signInHandler: signInFlowHandler,
            anisetteServerHandler: signInFlowHandler,
            skipDeviceRegistration: skipDeviceRegistration,
            skipCertificateProvisioning: skipCertificateProvisioning,
            skipResign: skipResign,
            skipHowTos: skipHowTos
        )
        let result = try await signInOperation.execute()
        self.team = result.team
        self.session = result.session
        return result
    }
    
    
    // Developer Portal Operations
    public func signIn(appleID: String, 
                       password: String, 
                       anisetteData: ALTAnisetteData, 
                       xcodeVersion: String, 
                       machinePassword: String? = nil,
                       accountRepairHandler: DeveloperPortal.AccountRepairHandler = DeveloperPortal.defaultAccountRepairHandler,
                       verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> (ALTAccount, ALTAppleAPISession) 
    {
        return try await self.portalProxy.signIn(
            appleID: appleID, 
            password: password, 
            anisetteData: anisetteData, 
            xcodeVersion: xcodeVersion, 
            machinePassword: machinePassword,
            accountRepairHandler: accountRepairHandler, 
            verificationHandler: verificationHandler
        )
    }
}

fileprivate extension DatabaseManager {
    //TODO: this is not clean, but for now this should be fine, ie we should later make this proper async instead of blocking
    func deactivateActiveAccountAndTeam() async {
        guard self.isStarted else {
            debugLog("[AuthManager] DatabaseManager is not started. Skipping CoreData active account/team deactivation.")
            return
        }
        let bgContext = self.persistentContainer.newBackgroundContext()
        await bgContext.perform {
            if let account = self.activeAccount(in: bgContext) {
                account.isActiveAccount = false
            }
            if let team = self.activeTeam(in: bgContext) {
                team.isActiveTeam = false
            }
            do {
                try bgContext.save()
            } catch {
                debugLog("[AuthManager] Failed to save CoreData context when deactivating active account and team: \(error)")
            }
        }
        
        await self.viewContext.perform {
            self.viewContext.processPendingChanges()
            self.viewContext.refreshAllObjects()
        }
    }
}
