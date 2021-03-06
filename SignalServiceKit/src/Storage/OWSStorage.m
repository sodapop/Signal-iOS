//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSStorage.h"
#import "AppContext.h"
#import "NSData+Base64.h"
#import "NSNotificationCenter+OWS.h"
#import "OWSFileSystem.h"
#import "OWSStorage+Subclass.h"
#import "TSAttachmentStream.h"
#import "TSStorageManager.h"
#import <Curve25519Kit/Randomness.h>
#import <SAMKeychain/SAMKeychain.h>
#import <YapDatabase/YapDatabase.h>
#import <YapDatabase/YapDatabaseCryptoUtils.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const StorageIsReadyNotification = @"StorageIsReadyNotification";

NSString *const OWSStorageExceptionName_DatabasePasswordInaccessibleWhileBackgrounded
    = @"OWSStorageExceptionName_DatabasePasswordInaccessibleWhileBackgrounded";
NSString *const OWSStorageExceptionName_DatabasePasswordUnwritable
    = @"OWSStorageExceptionName_DatabasePasswordUnwritable";
NSString *const OWSStorageExceptionName_NoDatabase = @"OWSStorageExceptionName_NoDatabase";
NSString *const OWSResetStorageNotification = @"OWSResetStorageNotification";

static NSString *keychainService = @"TSKeyChainService";
static NSString *keychainDBPassAccount = @"TSDatabasePass";
static NSString *keychainDBSalt = @"OWSDatabaseSalt";
static NSString *keychainDBKeySpec = @"OWSDatabaseKeySpec";

const NSUInteger kDatabasePasswordLength = 30;

typedef NSData *_Nullable (^LoadDatabaseMetadataBlock)(NSError **_Nullable);
typedef NSData *_Nullable (^CreateDatabaseMetadataBlock)(void);

#pragma mark -

@interface YapDatabaseConnection ()

- (id)initWithDatabase:(YapDatabase *)database;

@end

#pragma mark -

@implementation OWSDatabaseConnection

- (id)initWithDatabase:(YapDatabase *)database delegate:(id<OWSDatabaseConnectionDelegate>)delegate
{
    self = [super initWithDatabase:database];

    if (!self) {
        return self;
    }

    OWSAssert(delegate);

    _delegate = delegate;

    return self;
}

// Assert that the database is in a ready state (specifically that any sync database
// view registrations have completed and any async registrations have been started)
// before creating write transactions.
//
// Creating write transactions before the _sync_ database views are registered
// causes YapDatabase to rebuild all of our database views, which is catastrophic.
// Specifically, it causes YDB's "view version" checks to fail.
- (void)readWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
{
    id<OWSDatabaseConnectionDelegate> delegate = self.delegate;
    OWSAssert(delegate);
    OWSAssert(delegate.areAllRegistrationsComplete || self.canWriteBeforeStorageReady);

    [super readWriteWithBlock:block];
}

- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
{
    [self asyncReadWriteWithBlock:block completionQueue:NULL completionBlock:NULL];
}

- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
                completionBlock:(nullable dispatch_block_t)completionBlock
{
    [self asyncReadWriteWithBlock:block completionQueue:NULL completionBlock:completionBlock];
}

- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
                completionQueue:(nullable dispatch_queue_t)completionQueue
                completionBlock:(nullable dispatch_block_t)completionBlock
{
    id<OWSDatabaseConnectionDelegate> delegate = self.delegate;
    OWSAssert(delegate);
    OWSAssert(delegate.areAllRegistrationsComplete || self.canWriteBeforeStorageReady);

    [super asyncReadWriteWithBlock:block completionQueue:completionQueue completionBlock:completionBlock];
}

@end

#pragma mark -

// This class is only used in DEBUG builds.
@interface YapDatabase ()

- (void)addConnection:(YapDatabaseConnection *)connection;

- (YapDatabaseConnection *)registrationConnection;

@end

#pragma mark -

@interface OWSDatabase : YapDatabase

@property (atomic, weak) id<OWSDatabaseConnectionDelegate> delegate;

@property (atomic, nullable) YapDatabaseConnection *registrationConnectionCached;

- (instancetype)init NS_UNAVAILABLE;
- (id)initWithPath:(NSString *)inPath
        serializer:(nullable YapDatabaseSerializer)inSerializer
      deserializer:(YapDatabaseDeserializer)inDeserializer
           options:(YapDatabaseOptions *)inOptions
          delegate:(id<OWSDatabaseConnectionDelegate>)delegate NS_DESIGNATED_INITIALIZER;

@end

#pragma mark -

@implementation OWSDatabase

- (id)initWithPath:(NSString *)inPath
        serializer:(nullable YapDatabaseSerializer)inSerializer
      deserializer:(YapDatabaseDeserializer)inDeserializer
           options:(YapDatabaseOptions *)inOptions
          delegate:(id<OWSDatabaseConnectionDelegate>)delegate
{
    self = [super initWithPath:inPath serializer:inSerializer deserializer:inDeserializer options:inOptions];

    if (!self) {
        return self;
    }

    OWSAssert(delegate);

    _delegate = delegate;

    return self;
}

// This clobbers the superclass implementation to include asserts which
// ensure that the database is in a ready state before creating write transactions.
//
// See comments in OWSDatabaseConnection.
- (YapDatabaseConnection *)newConnection
{
    id<OWSDatabaseConnectionDelegate> delegate = self.delegate;
    OWSAssert(delegate);

    OWSDatabaseConnection *connection = [[OWSDatabaseConnection alloc] initWithDatabase:self delegate:delegate];
    [self addConnection:connection];
    return connection;
}

- (YapDatabaseConnection *)registrationConnection
{
    @synchronized(self)
    {
        if (!self.registrationConnectionCached) {
            YapDatabaseConnection *connection = [super registrationConnection];

#ifdef DEBUG
            // Flag the registration connection as such.
            OWSAssert([connection isKindOfClass:[OWSDatabaseConnection class]]);
            ((OWSDatabaseConnection *)connection).canWriteBeforeStorageReady = YES;
#endif

            self.registrationConnectionCached = connection;
        }
        return self.registrationConnectionCached;
    }
}

@end

#pragma mark -

@interface OWSUnknownDBObject : NSObject <NSCoding>

@end

#pragma mark -

/**
 * A default object to return when we can't deserialize an object from YapDB. This can prevent crashes when
 * old objects linger after their definition file is removed. The danger is that, the objects can lay in wait
 * until the next time a DB extension is added and we necessarily enumerate the entire DB.
 */
@implementation OWSUnknownDBObject

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder
{
    return nil;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
}

@end

#pragma mark -

@interface OWSUnarchiverDelegate : NSObject <NSKeyedUnarchiverDelegate>

@end

#pragma mark -

@implementation OWSUnarchiverDelegate

- (nullable Class)unarchiver:(NSKeyedUnarchiver *)unarchiver
    cannotDecodeObjectOfClassName:(NSString *)name
                  originalClasses:(NSArray<NSString *> *)classNames
{
    DDLogError(@"%@ Could not decode object: %@", self.logTag, name);
    OWSProdError([OWSAnalyticsEvents storageErrorCouldNotDecodeClass]);
    return [OWSUnknownDBObject class];
}

@end

#pragma mark -

@interface OWSStorage () <OWSDatabaseConnectionDelegate>

@property (atomic, nullable) YapDatabase *database;

@end

#pragma mark -

@implementation OWSStorage

- (instancetype)initStorage
{
    self = [super init];

    if (self) {
        if (![self tryToLoadDatabase]) {
            // Failing to load the database is catastrophic.
            //
            // The best we can try to do is to discard the current database
            // and behave like a clean install.
            OWSFail(@"%@ Could not load database", self.logTag);
            OWSProdCritical([OWSAnalyticsEvents storageErrorCouldNotLoadDatabase]);

            // Try to reset app by deleting all databases.
            //
            // TODO: Possibly clean up all app files.
            //            [OWSStorage deleteDatabaseFiles];

            if (![self tryToLoadDatabase]) {
                OWSFail(@"%@ Could not load database (second try)", self.logTag);
                OWSProdCritical([OWSAnalyticsEvents storageErrorCouldNotLoadDatabaseSecondAttempt]);

                // Sleep to give analytics events time to be delivered.
                [NSThread sleepForTimeInterval:15.0f];

                OWSRaiseException(OWSStorageExceptionName_NoDatabase, @"Failed to initialize database.");
            }
        }

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(resetStorage)
                                                     name:OWSResetStorageNotification
                                                   object:nil];
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (nullable id)dbNotificationObject
{
    OWSAssert(self.database);

    return self.database;
}

- (BOOL)areAsyncRegistrationsComplete
{
    OWS_ABSTRACT_METHOD();

    return NO;
}

- (BOOL)areSyncRegistrationsComplete
{
    OWS_ABSTRACT_METHOD();

    return NO;
}

- (BOOL)areAllRegistrationsComplete
{
    return self.areSyncRegistrationsComplete && self.areAsyncRegistrationsComplete;
}

- (void)runSyncRegistrations
{
    OWS_ABSTRACT_METHOD();
}

- (void)runAsyncRegistrationsWithCompletion:(void (^_Nonnull)(void))completion
{
    OWS_ABSTRACT_METHOD();
}

+ (NSArray<OWSStorage *> *)allStorages
{
    return @[
        TSStorageManager.sharedManager,
    ];
}

+ (void)setupStorage
{
    for (OWSStorage *storage in self.allStorages) {
        [storage runSyncRegistrations];
    }

    for (OWSStorage *storage in self.allStorages) {
        [storage runAsyncRegistrationsWithCompletion:^{
            
            [self postRegistrationCompleteNotificationIfPossible];

            ((OWSDatabase *)storage.database).registrationConnectionCached = nil;
        }];
    }
}

- (YapDatabaseConnection *)registrationConnection
{
    return self.database.registrationConnection;
}

+ (void)postRegistrationCompleteNotificationIfPossible
{
    if (!self.isStorageReady) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] postNotificationNameAsync:StorageIsReadyNotification
                                                                 object:nil
                                                               userInfo:nil];
    });
}

+ (BOOL)isStorageReady
{
    for (OWSStorage *storage in self.allStorages) {
        if (!storage.areAllRegistrationsComplete) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)tryToLoadDatabase
{
    // We determine the database password, salt and key spec first, since a side effect of
    // this can be deleting any existing database file (if we're recovering
    // from a corrupt keychain).
    //
    // Although we don't use databasePassword or databaseSalt in this method,
    // we use their accessors to ensure that all three exist in the keychain
    // and can be loaded or that we reset the database & keychain.
    NSData *databasePassword = [self databasePassword];
    OWSAssert(databasePassword.length > 0);
    NSData *databaseSalt = [self databaseSalt];
    OWSAssert(databaseSalt.length > 0);
    NSData *databaseKeySpec = [self databaseKeySpec];
    OWSAssert(databaseKeySpec.length == kSQLCipherKeySpecLength);

    YapDatabaseOptions *options = [[YapDatabaseOptions alloc] init];
    options.corruptAction = YapDatabaseCorruptAction_Fail;
    options.enableMultiProcessSupport = YES;
    options.cipherKeySpecBlock = ^{
        return databaseKeySpec;
    };
    options.cipherUnencryptedHeaderLength = kSqliteHeaderLength;

    // If any of these asserts fails, we need to verify and update
    // OWSDatabaseConverter which assumes the values of these options.
    OWSAssert(options.cipherDefaultkdfIterNumber == 0);
    OWSAssert(options.kdfIterNumber == 0);
    OWSAssert(options.cipherPageSize == 0);
    OWSAssert(options.pragmaPageSize == 0);
    OWSAssert(options.pragmaJournalSizeLimit == 0);
    OWSAssert(options.pragmaMMapSize == 0);

    OWSDatabase *database = [[OWSDatabase alloc] initWithPath:[self databaseFilePath]
                                                   serializer:nil
                                                 deserializer:[[self class] logOnFailureDeserializer]
                                                      options:options
                                                     delegate:self];

    if (!database) {
        return NO;
    }

    _database = database;

    return YES;
}

/**
 * NSCoding sometimes throws exceptions killing our app. We want to log that exception.
 **/
+ (YapDatabaseDeserializer)logOnFailureDeserializer
{
    OWSUnarchiverDelegate *unarchiverDelegate = [OWSUnarchiverDelegate new];

    return ^id(NSString __unused *collection, NSString __unused *key, NSData *data) {
        if (!data || data.length <= 0) {
            return nil;
        }

        @try {
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
            unarchiver.delegate = unarchiverDelegate;
            return [unarchiver decodeObjectForKey:@"root"];
        } @catch (NSException *exception) {
            // Sync log in case we bail.
            OWSProdError([OWSAnalyticsEvents storageErrorDeserialization]);
            @throw exception;
        }
    };
}

- (nullable YapDatabaseConnection *)newDatabaseConnection
{
    return self.database.newConnection;
}

- (BOOL)registerExtension:(YapDatabaseExtension *)extension withName:(NSString *)extensionName
{
    return [self.database registerExtension:extension withName:extensionName];
}

- (void)asyncRegisterExtension:(YapDatabaseExtension *)extension
                      withName:(NSString *)extensionName
{
    [self.database asyncRegisterExtension:extension
                                 withName:extensionName
                          completionBlock:^(BOOL ready) {
                              if (!ready) {
                                  OWSFail(@"%@ asyncRegisterExtension failed: %@", self.logTag, extensionName);
                              } else {
                                  DDLogVerbose(@"%@ asyncRegisterExtension succeeded: %@", self.logTag, extensionName);
                              }
                          }];
}

- (nullable id)registeredExtension:(NSString *)extensionName
{
    return [self.database registeredExtension:extensionName];
}

#pragma mark - Password

+ (void)deleteDatabaseFiles
{
    [OWSFileSystem deleteFile:[TSStorageManager databaseFilePath]];
}

- (void)deleteDatabaseFile
{
    [OWSFileSystem deleteFile:[self databaseFilePath]];
}

- (void)resetStorage
{
    self.database = nil;

    [self deleteDatabaseFile];
}

+ (void)resetAllStorage
{
    [[NSNotificationCenter defaultCenter] postNotificationName:OWSResetStorageNotification object:nil];

    // This might be redundant but in the spirit of thoroughness...
    [self deleteDatabaseFiles];

    [self deletePasswordFromKeychain];

    if (CurrentAppContext().isMainApp) {
        [TSAttachmentStream deleteAttachments];
    }

    // TODO: Delete Profiles on Disk?
}

#pragma mark - Password

- (NSString *)databaseFilePath
{
    OWS_ABSTRACT_METHOD();

    return @"";
}

#pragma mark - Keychain

+ (BOOL)isDatabasePasswordAccessible
{
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];
    NSError *error;
    NSString *dbPassword = [SAMKeychain passwordForService:keychainService account:keychainDBPassAccount error:&error];

    if (dbPassword && !error) {
        return YES;
    }

    if (error) {
        DDLogWarn(@"Database password couldn't be accessed: %@", error.localizedDescription);
    }

    return NO;
}

+ (nullable NSData *)tryToLoadKeyChainValue:(NSString *)keychainKey errorHandle:(NSError **)errorHandle
{
    OWSAssert(keychainKey.length > 0);
    OWSAssert(errorHandle);

    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];

    return [SAMKeychain passwordDataForService:keychainService account:keychainKey error:errorHandle];
}

+ (nullable NSData *)tryToLoadDatabasePassword:(NSError **)errorHandle
{
    return [self tryToLoadKeyChainValue:keychainDBPassAccount errorHandle:errorHandle];
}

+ (nullable NSData *)tryToLoadDatabaseSalt:(NSError **)errorHandle
{
    return [self tryToLoadKeyChainValue:keychainDBSalt errorHandle:errorHandle];
}

+ (nullable NSData *)tryToLoadDatabaseKeySpec:(NSError **)errorHandle
{
    return [self tryToLoadKeyChainValue:keychainDBKeySpec errorHandle:errorHandle];
}

- (NSData *)databasePassword
{
    return [self loadMetadataOrClearDatabase:^(NSError **_Nullable errorHandle) {
        return [OWSStorage tryToLoadDatabasePassword:errorHandle];
    }
        createDataBlock:^{
            NSData *passwordData = [self createAndSetNewDatabasePassword];
            NSData *saltData = [self createAndSetNewDatabaseSalt];
            NSData *keySpecData = [self createAndSetNewDatabaseKeySpec];

            OWSAssert(passwordData.length > 0);
            OWSAssert(saltData.length == kSQLCipherSaltLength);
            OWSAssert(keySpecData.length == kSQLCipherKeySpecLength);

            return passwordData;
        }
        label:@"Database password"];
}

- (NSData *)databaseSalt
{
    return [self loadMetadataOrClearDatabase:^(NSError **_Nullable errorHandle) {
        return [OWSStorage tryToLoadDatabaseSalt:errorHandle];
    }
        createDataBlock:^{
            NSData *passwordData = [self createAndSetNewDatabasePassword];
            NSData *saltData = [self createAndSetNewDatabaseSalt];
            NSData *keySpecData = [self createAndSetNewDatabaseKeySpec];

            OWSAssert(passwordData.length > 0);
            OWSAssert(saltData.length == kSQLCipherSaltLength);
            OWSAssert(keySpecData.length == kSQLCipherKeySpecLength);

            return saltData;
        }
        label:@"Database salt"];
}

- (NSData *)databaseKeySpec
{
    return [self loadMetadataOrClearDatabase:^(NSError **_Nullable errorHandle) {
        return [OWSStorage tryToLoadDatabaseKeySpec:errorHandle];
    }
        createDataBlock:^{
            OWSFail(@"%@ It should never be necessary to generate a random key spec.", self.logTag);

            NSData *passwordData = [self createAndSetNewDatabasePassword];
            NSData *saltData = [self createAndSetNewDatabaseSalt];
            NSData *keySpecData = [self createAndSetNewDatabaseKeySpec];

            OWSAssert(passwordData.length > 0);
            OWSAssert(saltData.length == kSQLCipherSaltLength);
            OWSAssert(keySpecData.length == kSQLCipherKeySpecLength);

            return keySpecData;
        }
        label:@"Database key spec"];
}

- (NSData *)loadMetadataOrClearDatabase:(LoadDatabaseMetadataBlock)loadDataBlock
                        createDataBlock:(CreateDatabaseMetadataBlock)createDataBlock
                                  label:(NSString *)label
{
    OWSAssert(loadDataBlock);
    OWSAssert(createDataBlock);

    NSError *error;
    NSData *_Nullable data = loadDataBlock(&error);

    if (error) {
        // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        // the keychain will be inaccessible after device restart until
        // device is unlocked for the first time.  If the app receives
        // a push notification, we won't be able to access the keychain to
        // process that notification, so we should just terminate by throwing
        // an uncaught exception.
        NSString *errorDescription =
            [NSString stringWithFormat:@"%@ inaccessible. No unlock since device restart? Error: %@", label, error];
        if (CurrentAppContext().isMainApp) {
            UIApplicationState applicationState = CurrentAppContext().mainApplicationState;
            errorDescription =
                [errorDescription stringByAppendingFormat:@", ApplicationState: %d", (int)applicationState];
        }
        DDLogError(@"%@ %@", self.logTag, errorDescription);
        [DDLog flushLog];

        if (CurrentAppContext().isMainApp) {
            if (CurrentAppContext().isInBackground) {
                // TODO: Rather than crash here, we should detect the situation earlier
                // and exit gracefully - (in the app delegate?). See the `
                // This is a last ditch effort to avoid blowing away the user's database.
                [self backgroundedAppDatabasePasswordInaccessibleWithErrorDescription:errorDescription];
            }
        } else {
            [self backgroundedAppDatabasePasswordInaccessibleWithErrorDescription:
                      [NSString stringWithFormat:@"%@ inaccessible; not main app.", label]];
        }

        // At this point, either this is a new install so there's no existing password to retrieve
        // or the keychain has become corrupt.  Either way, we want to get back to a
        // "known good state" and behave like a new install.

        BOOL shouldHaveDatabaseMetadata = [NSFileManager.defaultManager fileExistsAtPath:[self databaseFilePath]];
        if (shouldHaveDatabaseMetadata) {
            OWSFail(@"%@ Could not load database metadata", self.logTag);
            OWSProdCritical([OWSAnalyticsEvents storageErrorCouldNotLoadDatabaseSecondAttempt]);
        }

        // Try to reset app by deleting database.
        [OWSStorage resetAllStorage];

        data = createDataBlock();
    }

    return data;
}

- (NSData *)createAndSetNewDatabasePassword
{
    NSData *password = [[[Randomness generateRandomBytes:kDatabasePasswordLength] base64EncodedString]
        dataUsingEncoding:NSUTF8StringEncoding];

    [OWSStorage storeDatabasePassword:password];

    return password;
}

- (NSData *)createAndSetNewDatabaseSalt
{
    NSData *saltData = [Randomness generateRandomBytes:(int)kSQLCipherSaltLength];

    [OWSStorage storeDatabaseSalt:saltData];

    return saltData;
}

- (NSData *)createAndSetNewDatabaseKeySpec
{
    NSData *databasePassword = [self databasePassword];
    OWSAssert(databasePassword.length > 0);
    NSData *databaseSalt = [self databaseSalt];
    OWSAssert(databaseSalt.length == kSQLCipherSaltLength);

    NSData *keySpecData = [YapDatabaseCryptoUtils databaseKeySpecForPassword:databasePassword saltData:databaseSalt];
    OWSAssert(keySpecData.length == kSQLCipherKeySpecLength);

    [OWSStorage storeDatabaseKeySpec:keySpecData];

    return keySpecData;
}

- (void)backgroundedAppDatabasePasswordInaccessibleWithErrorDescription:(NSString *)errorDescription
{
    OWSAssert(CurrentAppContext().isMainApp && CurrentAppContext().isInBackground);

    // Sleep to give analytics events time to be delivered.
    [NSThread sleepForTimeInterval:5.0f];

    // Presumably this happened in response to a push notification. It's possible that the keychain is corrupted
    // but it could also just be that the user hasn't yet unlocked their device since our password is
    // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    OWSRaiseException(OWSStorageExceptionName_DatabasePasswordInaccessibleWhileBackgrounded, @"%@", errorDescription);
}

+ (void)deletePasswordFromKeychain
{
    [SAMKeychain deletePasswordForService:keychainService account:keychainDBPassAccount];
    [SAMKeychain deletePasswordForService:keychainService account:keychainDBSalt];
    [SAMKeychain deletePasswordForService:keychainService account:keychainDBKeySpec];
}

- (unsigned long long)databaseFileSize
{
    return [OWSFileSystem fileSizeOfPath:self.databaseFilePath].unsignedLongLongValue;
}

+ (void)storeKeyChainValue:(NSData *)data keychainKey:(NSString *)keychainKey
{
    OWSAssert(keychainKey.length > 0);
    OWSAssert(data.length > 0);

    NSError *error;
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];
    BOOL success = [SAMKeychain setPasswordData:data forService:keychainService account:keychainKey error:&error];
    if (!success || error) {
        OWSFail(@"%@ Could not store database metadata", self.logTag);
        OWSProdCritical([OWSAnalyticsEvents storageErrorCouldNotStoreKeychainValue]);

        [OWSStorage deletePasswordFromKeychain];

        // Sleep to give analytics events time to be delivered.
        [NSThread sleepForTimeInterval:15.0f];

        OWSRaiseException(
            OWSStorageExceptionName_DatabasePasswordUnwritable, @"Setting keychain value failed with error: %@", error);
    } else {
        DDLogWarn(@"Succesfully set new keychain value.");
    }
}

+ (void)storeDatabasePassword:(NSData *)passwordData
{
    [self storeKeyChainValue:passwordData keychainKey:keychainDBPassAccount];
}

+ (void)storeDatabaseSalt:(NSData *)saltData
{
    OWSAssert(saltData.length == kSQLCipherSaltLength);

    [self storeKeyChainValue:saltData keychainKey:keychainDBSalt];
}

+ (void)storeDatabaseKeySpec:(NSData *)keySpecData
{
    OWSAssert(keySpecData.length == kSQLCipherKeySpecLength);

    [self storeKeyChainValue:keySpecData keychainKey:keychainDBKeySpec];
}

@end

NS_ASSUME_NONNULL_END
