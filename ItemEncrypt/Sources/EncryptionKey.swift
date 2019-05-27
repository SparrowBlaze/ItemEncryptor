//
//  EncryptionKey.swift
//  ItemEncrypt
//
//  Created by James Robinson on 5/24/19.
//  Copyright © 2019 LeadDevCreations, LLC. All rights reserved.
//

import Foundation
import IDZSwiftCommonCrypto

/// A semantic representation of a symmetric key that can be used to encrypt and decrypt data.
public struct EncryptionKey: Equatable, Hashable {
    // MARK: Properties
    
    /// The encryption scheme this key uses.
    public let scheme: EncryptionSerialization.Scheme
    
    /// The key itself.
    public let keyData: [UInt8]
    
    /// The initialization vector (IV) used to derive this key.
    public let initializationVector: [UInt8]
    
    /// The salt used to derive this key.
    public let salt: [UInt8]
    
    /// A string identifying the key. Usually an account ID, email address, or some other moniker.
    public var context: String?
    
    /// A representation of the key as raw data. This may be stored or moved around where you'd like, but PLEASE keep it someplace secure!
    public var rawData: Data {
        // version + payload + iv + salt
        
        var res = scheme.version.rawValue
        res.append(contentsOf: keyData)
        res.append(contentsOf: initializationVector)
        res.append(contentsOf: salt)
        
        return Data(res)
    }
    
    // MARK: - Constructing an Encryption Key
    
    /// Derives a new random encryption key from the given password string and any additional data provided using the given encryption scheme.
    ///
    /// - important: This function generates a random seed (using `EncryptionSerialization.randomBytes(count:)`) for the key. DO NOT expect passing the same data to generate the same key.
    ///
    /// - parameter password: The raw password string from the user. This password is trimmed of leading and trailing whitespace, and Unicode normalized before being used to derive the key.
    /// - parameter additionalKeywords: Any array of contextual information (such as an account ID, email address, etc.) which should be tightly bound to the derived key.
    /// - parameter scheme: The encryption scheme (algorithm and configuration) to use to derive the key.
    public init(randomKeyFromPassword password: String, additionalKeywords: [String] = [], scheme: EncryptionSerialization.Scheme) {
        
        let seed = EncryptionSerialization.randomBytes(count: scheme.seedSize)
        let iv = EncryptionSerialization.randomBytes(count: scheme.initializationVectorSize)
        
        try! self.init(untreatedPassword: password,
                  additionalKeywords: additionalKeywords,
                  seed: seed,
                  iv: iv,
                  scheme: scheme)
    }
    
    /// Derives an encryption key from a password and additional provided data using the given encryption scheme.
    ///
    /// This method calls `EncryptionKey(untreatedPassword:treatedSalt:iv:scheme:)`. The `seed` parameter, mixed with `additionalKeywords`, is used to derive the salt.
    ///
    /// - parameter untreatedPassword: A raw password string from the user. This password is trimmed of leading and trailing whitespace, and Unicode normalized before being used to derive the key.
    /// - parameter additionalKeywords: Any array of contextual information (such as an account ID, email address, etc.) which should be tightly bound to the derived key.
    /// - parameter seed: Some data which is used to derive the key. It is not considered sensitive data. This value MUST match the given encryption scheme's `stretchedSaltSize` to be valid.
    /// - parameter iv: The initialization vector (IV) to use to derive the key. It is not considered sensitive data. This value MUST match the given encryption scheme's `initializationVectorSize` to be valid.
    /// - parameter scheme: The encryption scheme (algorithm and configuration) to use to derive the key.
    ///
    /// - throws: An `ImproperKey` error if the seed or IV are the wrong size for the given scheme. Inspect `scheme` for proper sizes.
    public init(untreatedPassword: String, additionalKeywords: [String] = [], seed: [UInt8], iv: [UInt8], scheme: EncryptionSerialization.Scheme) throws {
        
        guard seed.count == scheme.seedSize else {
            NSLog("Incoming seed was the wrong size <\(seed.count)> for the encryption scheme <\(scheme.seedSize)>.")
            throw ImproperKey.seedSize(expectation: scheme.seedSize, reality: seed.count)
        }
        
        // Get a salt from the seed and additional keywords.
        var hasher = HMAC(algorithm: scheme.hmacAlgorithm, key: seed)
        for data in additionalKeywords {
            // Hash in the email, user ID, etc. passed in.
            hasher = hasher.update(string: data)!
        }
        
        let treatedSalt = hasher.final()
        
        try self.init(untreatedPassword: untreatedPassword,
                  treatedSalt: treatedSalt,
                  iv: iv,
                  scheme: scheme)
    }
    
    /// Derives an encryption key from a password, a previously treated salt, an initialization vector, and the given encryption scheme.
    ///
    /// - parameter untreatedPassword: A raw password string from the user. This password is trimmed of leading and trailing whitespace, and Unicode normalized before being used to derive the key.
    /// - parameter treatedSalt: Some data used to derive the key. It is not considered sensitive data. This value MUST match the given encryption scheme's `stretchedSaltSize` to be valid.
    /// - parameter iv: The initialization vector (IV) to use to derive the key. It is not considered sensitive data. This value MUST match the given encryption scheme's `initializationVectorSize` to be valid.
    /// - parameter scheme: The encryption scheme (algorithm and configuration) to use to encrypt and decrypt data.
    ///
    /// - throws: An `ImproperKey` error if the salt or IV are the wrong size for the given scheme. Inspect `scheme` for proper sizes.
    public init(untreatedPassword: String, treatedSalt: [UInt8], iv: [UInt8], scheme: EncryptionSerialization.Scheme) throws {
        
        self.scheme = scheme
        
        // Trimmed and normalized password
        let treatedPassword = untreatedPassword.trimmingCharacters(in: .whitespacesAndNewlines).decomposedStringWithCompatibilityMapping
        
        // Treated salt
        guard treatedSalt.count == scheme.stretchedSaltSize else {
            NSLog("Incoming salt was the wrong size <\(treatedSalt.count)> for the encryption scheme <\(scheme.stretchedSaltSize)>.")
            throw ImproperKey.saltSize(expectation: scheme.stretchedSaltSize, reality: treatedSalt.count)
        }
        
        // Initialization vector
        guard iv.count == scheme.initializationVectorSize else {
            NSLog("Incoming IV was the wrong size <\(iv.count)> for the encryption scheme <\(scheme.initializationVectorSize)>.")
            throw ImproperKey.initializationVectorSize(expectation: scheme.initializationVectorSize, reality: iv.count)
        }
        
        self.salt = treatedSalt
        self.initializationVector = iv
        
        self.keyData = EncryptionSerialization.deriveKey(password: treatedPassword,
                                                         salt: salt,
                                                         scheme: scheme)
    }
    
    /// Attempts to create a semantic `EncryptionKey` from raw data.
    ///
    /// - throws: An `ImproperKey` error if `data` is not any valid `EncryptionKey` format.
    public init(data: Data) throws {
        // Configuration tells us how to look at this data.
        
        var iv = [UInt8]()
        var salt = [UInt8]()
        var keyData = [UInt8]()
        var version = EncryptionSerialization.Scheme.Format.primary
        
        self.scheme = try EncryptionKey.parseData(data,
                                                  into: &keyData,
                                                  initializationVector: &iv,
                                                  resultSalt: &salt,
                                                  version: &version)
        
        self.initializationVector = iv
        self.salt = salt
        self.keyData = keyData
    }
    
    /// Attempts to parse given data into semantic version format ID, innitialization vector, salt, and payload blocks.
    private static func parseData(_ data: Data,
                                  into resultPayload: inout [UInt8],
                                  initializationVector: inout [UInt8],
                                  resultSalt: inout [UInt8],
                                  version: inout EncryptionSerialization.Scheme.Format) throws -> EncryptionSerialization.Scheme {
        
        // version + payload + iv + salt
        var mutableData = data
        
        // Get version
        let expectedVersionSize = EncryptionSerialization.Scheme.Format.dataSize
        let expectedVersionData = mutableData[mutableData.startIndex..<expectedVersionSize]
        guard let foundVersion =
            EncryptionSerialization.Scheme.Format(bytes: [UInt8](expectedVersionData)) else {
                throw ImproperKey.badFormatData
        }
        version = foundVersion
        
        mutableData = mutableData.subdata(in: expectedVersionSize..<mutableData.endIndex)
        let scheme = EncryptionSerialization.Scheme(format: version)
        
        // Get salt
        let saltSize = scheme.stretchedSaltSize
        let saltStart = mutableData.endIndex.advanced(by: -saltSize)
        let expectedSaltData = mutableData[saltStart..<mutableData.count]
        resultSalt = [UInt8](expectedSaltData)
        
        mutableData = mutableData.subdata(in: mutableData.startIndex..<saltStart)
        
        // Get initialization vector
        let vectorSize = scheme.initializationVectorSize
        let vectorStart = mutableData.endIndex.advanced(by: -vectorSize)
        let expectedVectorData = mutableData[vectorStart..<mutableData.count]
        initializationVector = [UInt8](expectedVectorData)
        
        mutableData = mutableData.subdata(in: mutableData.startIndex..<vectorStart)
        
        resultPayload = [UInt8](mutableData)
        
        return scheme
    }
    
    enum ImproperKey: Error {
        case badFormatData
        case initializationVectorSize(expectation: Int, reality: Int)
        case saltSize(expectation: Int, reality: Int)
        case seedSize(expectation: Int, reality: Int)
    }
    
}

// MARK: - Equatable and Hashable

extension EncryptionKey {
    
    public static func == (lhs: EncryptionKey, rhs: EncryptionKey) -> Bool {
        return lhs.scheme == rhs.scheme &&
            lhs.initializationVector == rhs.initializationVector &&
            lhs.salt == rhs.salt &&
            lhs.keyData == rhs.keyData &&
            lhs.context == rhs.context
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(scheme)
        hasher.combine(initializationVector)
        hasher.combine(salt)
        hasher.combine(keyData)
        hasher.combine(context)
    }
    
}
