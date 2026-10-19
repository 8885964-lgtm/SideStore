//
//  Keychain.swift
//  AltStore
//
//  Created by Riley Testut on 6/4/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
private import KeychainAccess
import SideSign

@propertyWrapper
public struct KeychainItem<Value>
{
    public let key: String
    
    public var wrappedValue: Value? {
        get {
            if let overridden = Keychain.shared.accountOverrideValue(forKey: self.key)
            {
                return overridden.value as? Value
            }
            
            switch Value.self
            {
            case is Data.Type: return try? Keychain.shared.keychain.getData(self.key) as? Value
            case is String.Type: return try? Keychain.shared.keychain.getString(self.key) as? Value
            default: return nil
            }
        }
        set {
            if Keychain.shared.setAccountOverrideValue(newValue, forKey: self.key)
            {
                return
            }
            
            switch Value.self
            {
            case is Data.Type: Keychain.shared.keychain[data: self.key] = newValue as? Data
            case is String.Type: Keychain.shared.keychain[self.key] = newValue as? String
            default: break
            }
        }
    }
    
    public init(key: String)
    {
        self.key = key
    }
}

/// The keychain values that make up one Apple ID sign-in.
struct KeychainAccountSlots: Equatable
{
    var appleIDEmailAddress: String?
    var appleIDPassword: String?
    var appleIDAdsid: String?
    var appleIDXcodeToken: String?
    var signingCertificate: Data?
    var signingCertificatePassword: String?
}

// Must match the @KeychainItem keys of the Apple ID properties in Keychain.
private enum KeychainAccountKey
{
    static let email = "appleIDEmailAddress"
    static let password = "appleIDPassword"
    static let adsid = "appleIDAdsid"
    static let xcodeToken = "appleIDXcodeToken"
    static let certificate = "signingCertificate"
    static let certificatePassword = "signingCertificatePassword"
    
    static let all: Set<String> = [email, password, adsid, xcodeToken, certificate, certificatePassword]
}

private struct KeychainOverrideValue
{
    let value: Any?
}

public class Keychain
{
    public static let shared = Keychain()
    
    fileprivate let keychain = KeychainAccess.Keychain(service: Bundle.Info.appbundleIdentifier)
                                            .accessibility(.afterFirstUnlock)
                                            .synchronizable(true)
    
    @KeychainItem(key: "appleIDEmailAddress")
    public var appleIDEmailAddress: String?
    
    @KeychainItem(key: "appleIDPassword")
    public var appleIDPassword: String?
    
    @KeychainItem(key: "appleIDAdsid")
    public var appleIDAdsid: String?
    
    @KeychainItem(key: "appleIDXcodeToken")
    public var appleIDXcodeToken: String?
    
    @KeychainItem(key: "signingCertificate")
    public var signingCertificate: Data?
    
    @KeychainItem(key: "signingCertificatePassword")
    public var signingCertificatePassword: String?
    
    // TODO: mahee96: remove legacy keys in later versions after 0.6.4 coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificatePrivateKey")
    public var signingCertificatePrivateKey: Data?
    
    // TODO: mahee96: remove legacy keys in later versions after 0.6.4 coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificateSerialNumber")
    public var signingCertificateSerialNumber: String?
    
    @KeychainItem(key: "identifier")
    public var identifier: String?
    
    @KeychainItem(key: "adiPb")
    public var adiPb: String?

    @KeychainItem(key: "deviceUDID")
    public var deviceUDID: String?

    // MARK: - Dynamic Imported Certificates Storage

    public subscript(certificateSerial serial: String) -> Data? {
        get { try? self.keychain.getData("importedCert_" + serial) }
        set {
            if let data = newValue {
                try? self.keychain.set(data, key: "importedCert_" + serial)
            } else {
                try? self.keychain.remove("importedCert_" + serial)
            }
        }
    }
    
    private init()
    {
        self.migrateLegacyKeychainItems()
    }
    
    private func migrateLegacyKeychainItems()
    {
        let signingCertificateKey   = "signingCertificate"
        let privateKeyKey           = "signingCertificatePrivateKey"
        let serialNumberKey         = "signingCertificateSerialNumber"
        
        // 1. Check if signingCertificate contains data and is NOT a PKCS#12 archive
        guard let certData = try? self.keychain.getData(signingCertificateKey), !certData.isPKCS12 else { return }
        
        // 2. Check if we have the private key
        guard let privateKey = try? self.keychain.getData(privateKeyKey) else { return }
        
        // 3. Load the raw certificate and pair with private key
        guard let x509 = ALTX509Certificate(data: certData) else { return }
        let cert = ALTCertificate(x509: x509, privateKey: privateKey)
        
        // 4. Create PKCS12 data structure
        do {
            let p12Data = try cert.unencryptedP12Data()
            // 5. Store the new PKCS12 format in signingCertificate slot
            try self.keychain.set(p12Data, key: signingCertificateKey)
            try self.keychain.set("", key: "signingCertificatePassword")
            
            // 6. Clear legacy keys
            try self.keychain.remove(privateKeyKey)
            try self.keychain.remove(serialNumberKey)
            
            debugLog("[Keychain] Successfully migrated legacy certificate and private key to PKCS12 format and cleared legacy keys.")
        } catch {
            debugLog("[Keychain] Failed to migrate legacy certificate to PKCS12 format: \(error)")
        }
    }
    
    public func clearCertificates()
    {
        // Legacy
        self.signingCertificatePrivateKey = nil
        self.signingCertificateSerialNumber = nil

        self.signingCertificate = nil
        self.signingCertificatePassword = nil
        
        debugLog("[Keychain] Cleared signing certificate & private key from Keychain.")
    }
    
    public func clearSignInInfo(keepAnisetteData: Bool = true)
    {
        debugLog("[Keychain] Clearing sign-in info from Keychain (keepAnisetteData: \(keepAnisetteData))...")
        
        self.appleIDEmailAddress = nil
        self.appleIDPassword = nil
        self.appleIDAdsid = nil
        self.appleIDXcodeToken = nil
        debugLog("[Keychain] Cleared Apple ID credentials & tokens (email, password, adsid, xcodeToken).")

        if !keepAnisetteData {
            self.adiPb = nil
            debugLog("[Keychain] Cleared Anisette ADI data (adiPb).")
        } else {
            debugLog("[Keychain] Preserved Anisette ADI data (adiPb).")
        }
        
        debugLog("[Keychain] Cleared sign-in info from Keychain.")
    }

    public func clearAll()
    {
        debugLog("[Keychain] Clearing all Keychain items related to this instance...")
        try? self.keychain.removeAll()
        debugLog("[Keychain] All Keychain items cleared.")
    }

    // MARK: - Named slots
    //
    // Additional Apple IDs are stored beside the legacy single-account keys,
    // using the same keychain service and accessibility.

    public func storedString(for key: String) -> String? {
        try? self.keychain.getString(key)
    }

    public func setStoredString(_ value: String?, for key: String) {
        if let value {
            try? self.keychain.set(value, key: key)
        } else {
            try? self.keychain.remove(key)
        }
    }

    public func storedData(for key: String) -> Data? {
        try? self.keychain.getData(key)
    }

    public func setStoredData(_ value: Data?, for key: String) {
        if let value {
            try? self.keychain.set(value, key: key)
        } else {
            try? self.keychain.remove(key)
        }
    }
    
    // MARK: - Account override
    //
    // While an override is active, the Apple ID keys read and write memory instead of the keychain,
    // so another Apple ID can sign a batch without the stored sign-in changing (or syncing) underneath.
    
    private let accountOverrideLock = NSLock()
    private var accountOverride: [String: Any]?
    
    var isAccountOverrideActive: Bool
    {
        self.accountOverrideLock.lock()
        defer { self.accountOverrideLock.unlock() }
        return self.accountOverride != nil
    }
    
    /// The Apple ID keys as the app currently sees them, including an active override.
    var accountSlots: KeychainAccountSlots
    {
        self.accountOverrideLock.lock()
        defer { self.accountOverrideLock.unlock() }
        
        if let values = self.accountOverride
        {
            return Keychain.slots(fromOverride: values)
        }
        
        return KeychainAccountSlots(
            appleIDEmailAddress: try? self.keychain.getString(KeychainAccountKey.email),
            appleIDPassword: try? self.keychain.getString(KeychainAccountKey.password),
            appleIDAdsid: try? self.keychain.getString(KeychainAccountKey.adsid),
            appleIDXcodeToken: try? self.keychain.getString(KeychainAccountKey.xcodeToken),
            signingCertificate: try? self.keychain.getData(KeychainAccountKey.certificate),
            signingCertificatePassword: try? self.keychain.getString(KeychainAccountKey.certificatePassword)
        )
    }
    
    /// Replaces every Apple ID key at once, in the override when one is active.
    func setAccountSlots(_ slots: KeychainAccountSlots)
    {
        self.accountOverrideLock.lock()
        defer { self.accountOverrideLock.unlock() }
        
        if self.accountOverride != nil
        {
            self.accountOverride = Keychain.overrideValues(for: slots)
            return
        }
        
        self.keychain[KeychainAccountKey.email] = slots.appleIDEmailAddress
        self.keychain[KeychainAccountKey.password] = slots.appleIDPassword
        self.keychain[KeychainAccountKey.adsid] = slots.appleIDAdsid
        self.keychain[KeychainAccountKey.xcodeToken] = slots.appleIDXcodeToken
        self.keychain[data: KeychainAccountKey.certificate] = slots.signingCertificate
        self.keychain[KeychainAccountKey.certificatePassword] = slots.signingCertificatePassword
    }
    
    func beginAccountOverride(_ slots: KeychainAccountSlots)
    {
        self.accountOverrideLock.lock()
        defer { self.accountOverrideLock.unlock() }
        self.accountOverride = Keychain.overrideValues(for: slots)
    }
    
    /// Ends the override and returns the values it ended with.
    @discardableResult
    func endAccountOverride() -> KeychainAccountSlots?
    {
        self.accountOverrideLock.lock()
        defer { self.accountOverrideLock.unlock() }
        
        guard let values = self.accountOverride else { return nil }
        self.accountOverride = nil
        return Keychain.slots(fromOverride: values)
    }
    
    fileprivate func accountOverrideValue(forKey key: String) -> KeychainOverrideValue?
    {
        guard KeychainAccountKey.all.contains(key) else { return nil }
        
        self.accountOverrideLock.lock()
        defer { self.accountOverrideLock.unlock() }
        
        guard let values = self.accountOverride else { return nil }
        return KeychainOverrideValue(value: values[key])
    }
    
    fileprivate func setAccountOverrideValue(_ value: Any?, forKey key: String) -> Bool
    {
        guard KeychainAccountKey.all.contains(key) else { return false }
        
        self.accountOverrideLock.lock()
        defer { self.accountOverrideLock.unlock() }
        
        guard self.accountOverride != nil else { return false }
        self.accountOverride?[key] = value
        return true
    }
    
    private static func overrideValues(for slots: KeychainAccountSlots) -> [String: Any]
    {
        var values = [String: Any]()
        values[KeychainAccountKey.email] = slots.appleIDEmailAddress
        values[KeychainAccountKey.password] = slots.appleIDPassword
        values[KeychainAccountKey.adsid] = slots.appleIDAdsid
        values[KeychainAccountKey.xcodeToken] = slots.appleIDXcodeToken
        values[KeychainAccountKey.certificate] = slots.signingCertificate
        values[KeychainAccountKey.certificatePassword] = slots.signingCertificatePassword
        return values
    }
    
    private static func slots(fromOverride values: [String: Any]) -> KeychainAccountSlots
    {
        KeychainAccountSlots(
            appleIDEmailAddress: values[KeychainAccountKey.email] as? String,
            appleIDPassword: values[KeychainAccountKey.password] as? String,
            appleIDAdsid: values[KeychainAccountKey.adsid] as? String,
            appleIDXcodeToken: values[KeychainAccountKey.xcodeToken] as? String,
            signingCertificate: values[KeychainAccountKey.certificate] as? Data,
            signingCertificatePassword: values[KeychainAccountKey.certificatePassword] as? String
        )
    }
}
