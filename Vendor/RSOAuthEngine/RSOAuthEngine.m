//
//  RSOAuthEngine.m
//
//  Created by Rodrigo Sieiro on 12/11/11.
//  Copyright (c) 2012 Rodrigo Sieiro <rsieiro@sharpcube.com>. All rights reserved.

#include <sys/time.h>
#import <CommonCrypto/CommonHMAC.h>
#import "NSData+MKBase64.h"
#import "NSString+MKNetworkKitAdditions.h"
#import "RSOAuthEngine.h"

static const NSString *oauthVersion = @"1.0";

static const NSString *oauthSignatureMethodName[] = {
    @"PLAINTEXT",
    @"HMAC-SHA1",
};

// This category for MKNetworkOperation was added
// Because we need access to these fields
// And they are private inside the class

@interface MKNetworkOperation (RSO)

@property (strong, nonatomic) NSMutableArray *filesToBePosted;
@property (strong, nonatomic) NSMutableArray *dataToBePosted;

@end

@implementation MKNetworkOperation (RSO)

@dynamic filesToBePosted;
@dynamic dataToBePosted;

@end

@interface RSOAuthEngine ()

- (NSString *)signatureBaseStringForURL:(NSString *)url method:(NSString *)method parameters:(NSMutableArray *)parameters;
- (NSString *)signatureBaseStringForRequest:(MKNetworkOperation *)request;
- (NSString *)generatePlaintextSignatureFor:(NSString *)baseString;
- (NSString *)generateHMAC_SHA1SignatureFor:(NSString *)baseString;
- (void)addCustomValue:(NSString *)value withKey:(NSString *)key;
- (void)setOAuthValue:(NSString *)value forKey:(NSString *)key;

@end

@implementation RSOAuthEngine

#pragma mark - Read-only Properties

- (RSOAuthTokenType)tokenType {
    return _tokenType;
}

- (RSOAuthSignatureMethod)signatureMethod {
    return _signatureMethod;
}

- (NSString *)consumerKey {
    return (_oAuthValues) ? [_oAuthValues objectForKey:@"oauth_consumer_key"] : @"";
}

- (NSString *)consumerSecret {
    return _consumerSecret;
}

- (NSString *)callbackURL {
    return _callbackURL;
}

- (NSString *)token {
    return (_oAuthValues) ? [_oAuthValues objectForKey:@"oauth_token"] : @"";
}

- (NSString *)tokenSecret {
    return _tokenSecret;
}

- (NSString *)verifier {
    return _verifier;
}

#pragma mark - Initialization

- (id)initWithHostName:(NSString *)hostName
    customHeaderFields:(NSDictionary *)headers
       signatureMethod:(RSOAuthSignatureMethod)signatureMethod
           consumerKey:(NSString *)consumerKey
        consumerSecret:(NSString *)consumerSecret
           callbackURL:(NSString *)callbackURL
{
    NSAssert(consumerKey, @"Consumer Key cannot be null");
    NSAssert(consumerSecret, @"Consumer Secret cannot be null");
    
    self = [super initWithHostName:hostName customHeaderFields:headers];
    
    if (self) {
        _consumerSecret = consumerSecret;
        _callbackURL = callbackURL;
        _signatureMethod = signatureMethod;
        
        _oAuthValues = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                        oauthVersion, @"oauth_version",
                        oauthSignatureMethodName[_signatureMethod], @"oauth_signature_method",
                        consumerKey, @"oauth_consumer_key",
                        @"", @"oauth_token",
                        @"", @"oauth_verifier",
                        @"", @"oauth_callback",
                        @"", @"oauth_signature",
                        @"", @"oauth_timestamp",
                        @"", @"oauth_nonce",
                        @"", @"realm",
                        nil];
        
        [self resetOAuthToken];
    }
    
    return self;
}

- (id)initWithHostName:(NSString *)hostName
    customHeaderFields:(NSDictionary *)headers
       signatureMethod:(RSOAuthSignatureMethod)signatureMethod
           consumerKey:(NSString *)consumerKey
        consumerSecret:(NSString *)consumerSecret
{
    return [self initWithHostName:hostName
               customHeaderFields:headers
                  signatureMethod:signatureMethod
                      consumerKey:consumerKey
                   consumerSecret:consumerSecret
                      callbackURL:nil];
}

#pragma mark - OAuth Signature Generators

- (NSString *)signatureBaseStringForURL:(NSString *)url method:(NSString *)method parameters:(NSMutableArray *)parameters
{
    if (!parameters) {
        parameters = [NSMutableArray arrayWithCapacity:[_oAuthValues count]];
    }
    
    // Add parameters from the OAuth header
    for (NSString *key in _oAuthValues) {
        NSString *obj = [_oAuthValues objectForKey:key];
        if ([key hasPrefix:@"oauth_"]  && ![key isEqualToString:@"oauth_signature"] && obj && ![obj isEqualToString:@""]) {
            [parameters addObject:[NSDictionary dictionaryWithObjectsAndKeys:[key mk_urlEncodedString], @"key", [obj mk_urlEncodedString], @"value", nil]];
        }
    }
    
    // Sort by name and value
    [parameters sortUsingComparator:^(id obj1, id obj2) {
        NSDictionary *val1 = obj1, *val2 = obj2;
        NSComparisonResult result = [[val1 objectForKey:@"key"] compare:[val2 objectForKey:@"key"] options:NSLiteralSearch];
        if (result != NSOrderedSame) return result;
        return [[val1 objectForKey:@"value"] compare:[val2 objectForKey:@"value"] options:NSLiteralSearch];
    }];
    
    // Join sorted components
    NSMutableArray *normalizedParameters = [NSMutableArray array];
    for (NSDictionary *obj in parameters) {
        [normalizedParameters addObject:[NSString stringWithFormat:@"%@=%@", [obj objectForKey:@"key"], [obj objectForKey:@"value"]]];
    }
    
    // Create the signature base string
    NSString *signatureBaseString = [NSString stringWithFormat:@"%@&%@&%@",
                                     [method uppercaseString],
                                     [url mk_urlEncodedString],
                                     [[normalizedParameters componentsJoinedByString:@"&"] mk_urlEncodedString]];
    
    return signatureBaseString;
}

- (NSString *)signatureBaseStringForRequest:(MKNetworkOperation *)request
{
    NSMutableArray *parameters = [NSMutableArray array];
    NSURL *url = [NSURL URLWithString:request.url];

    // Get the base URL String (with no parameters)
    NSArray *urlParts = [request.url componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    NSString *baseURL = [urlParts objectAtIndex:0];

    // Only include GET and POST fields if there are no files or data to be posted
    if ([request.filesToBePosted count] == 0 && [request.dataToBePosted count] == 0) {
        // Add parameters from the query string
        NSArray *pairs = [url.query componentsSeparatedByString:@"&"];
        for (NSString *obj in pairs) {
            NSArray *elements = [obj componentsSeparatedByString:@"="];
            NSString *key = [elements objectAtIndex:0];
            NSString *value = (elements.count > 1) ? [elements objectAtIndex:1] : @"";
            
            [parameters addObject:[NSDictionary dictionaryWithObjectsAndKeys:key, @"key", value, @"value", nil]];
        }
        
        // Add parameters from the request body
        // Only if we're POSTing, GET parameters were already added
        if ([[[request HTTPMethod] uppercaseString] isEqualToString:@"POST"]) {
            for (NSString *key in request.readonlyPostDictionary) {
                NSString *obj = [request.readonlyPostDictionary objectForKey:key];
                [parameters addObject:[NSDictionary dictionaryWithObjectsAndKeys:[key mk_urlEncodedString], @"key", [obj mk_urlEncodedString], @"value", nil]];
            }
        }
    }
    
    return [self signatureBaseStringForURL:baseURL method:[request HTTPMethod] parameters:parameters];
}

- (NSString *)generatePlaintextSignatureFor:(NSString *)baseString
{
    return [NSString stringWithFormat:@"%@&%@", 
            self.consumerSecret != nil ? [self.consumerSecret mk_urlEncodedString] : @"", 
            self.tokenSecret != nil ? [self.tokenSecret mk_urlEncodedString] : @""];
}

- (NSString *)generateHMAC_SHA1SignatureFor:(NSString *)baseString
{
    NSString *key = [self generatePlaintextSignatureFor:baseString];
    
    const char *keyBytes = [key cStringUsingEncoding:NSUTF8StringEncoding];
    const char *baseStringBytes = [baseString cStringUsingEncoding:NSUTF8StringEncoding];
    unsigned char digestBytes[CC_SHA1_DIGEST_LENGTH];
    
	CCHmacContext ctx;
    CCHmacInit(&ctx, kCCHmacAlgSHA1, keyBytes, strlen(keyBytes));
	CCHmacUpdate(&ctx, baseStringBytes, strlen(baseStringBytes));
	CCHmacFinal(&ctx, digestBytes);
    
	NSData *digestData = [NSData dataWithBytes:digestBytes length:CC_SHA1_DIGEST_LENGTH];
    return [digestData base64EncodedString];
}

#pragma mark - Dictionary Helpers

- (void)addCustomValue:(NSString *)value withKey:(NSString *)key
{
    if (!key) return;
    if (!_customValues) _customValues = [[NSMutableDictionary alloc] initWithCapacity:1];

    if (value) {
        [_customValues setObject:value forKey:key];
    } else {
        [_customValues setObject:@"" forKey:key];
    }
}

- (void)setOAuthValue:(NSString *)value forKey:(NSString *)key
{
    if (!key) return;
    if (value) {
        [_oAuthValues setObject:value forKey:key];
    } else {
        [_oAuthValues setObject:@"" forKey:key];
    }
}

#pragma mark - Public Methods

- (BOOL)isAuthenticated
{
    return (_tokenType == RSOAuthAccessToken && self.token && self.tokenSecret);
}

- (void)resetOAuthToken
{
    _tokenType = RSOAuthRequestToken;
    _tokenSecret = nil;
    _verifier = nil;
    _customValues = nil;
    
    [self setOAuthValue:self.callbackURL forKey:@"oauth_callback"];
    [self setOAuthValue:@"" forKey:@"oauth_verifier"];
    [self setOAuthValue:@"" forKey:@"oauth_token"];
}

- (NSString *)customValueForKey:(NSString *)key
{
    if (!_customValues) return nil;
    return [_customValues objectForKey:key];
}

- (void)fillTokenWithResponseBody:(NSString *)body type:(RSOAuthTokenType)tokenType
{
    NSArray *pairs = [body componentsSeparatedByString:@"&"];

    for (NSString *pair in pairs)
    {
        NSArray *elements = [pair componentsSeparatedByString:@"="];
        NSString *key = [elements objectAtIndex:0];
        NSString *value = [[elements objectAtIndex:1] mk_urlDecodedString];
        
        if ([key isEqualToString:@"oauth_token"]) {
            [self setOAuthValue:value forKey:@"oauth_token"];
        } else if ([key isEqualToString:@"oauth_token_secret"]) {
            _tokenSecret = value;
        } else if ([key isEqualToString:@"oauth_verifier"]) {
            _verifier = value;
        } else {
            [self addCustomValue:value withKey:key];
        }
    }
    
    _tokenType = tokenType;
    
    // If we already have an Access Token, no need to send the Verifier and Callback URL
    if (_tokenType == RSOAuthAccessToken) {
        [self setOAuthValue:nil forKey:@"oauth_callback"];
        [self setOAuthValue:nil forKey:@"oauth_verifier"];
    } else {
        [self setOAuthValue:self.callbackURL forKey:@"oauth_callback"];
        [self setOAuthValue:self.verifier forKey:@"oauth_verifier"];
    }
}

- (void)setAccessToken:(NSString *)token secret:(NSString *)tokenSecret
{
    NSAssert(token, @"Token cannot be null");
    NSAssert(tokenSecret, @"Token Secret cannot be null");
    
    [self resetOAuthToken];
    
    [self setOAuthValue:token forKey:@"oauth_token"];
    _tokenSecret = tokenSecret;
    _tokenType = RSOAuthAccessToken;

    // Since we already have an Access Token, no need to send the Verifier and Callback URL
    [self setOAuthValue:nil forKey:@"oauth_callback"];
    [self setOAuthValue:nil forKey:@"oauth_verifier"];
}

- (void)signRequest:(MKNetworkOperation *)request
{
    NSAssert(_oAuthValues && self.consumerKey && self.consumerSecret, @"Please use an initializer with Consumer Key and Consumer Secret.");

    // Generate timestamp and nonce values
    [self setOAuthValue:[NSString stringWithFormat:@"%ld", time(NULL)] forKey:@"oauth_timestamp"];
    [self setOAuthValue:[NSString mk_uniqueString] forKey:@"oauth_nonce"];
    
    // Construct the signature base string
    NSString *baseString = [self signatureBaseStringForRequest:request];
    
    // Generate the signature
    switch (_signatureMethod) {
        case RSOAuthHMAC_SHA1:
            [self setOAuthValue:[self generateHMAC_SHA1SignatureFor:baseString] forKey:@"oauth_signature"];
            break;
        default:
            [self setOAuthValue:[self generatePlaintextSignatureFor:baseString] forKey:@"oauth_signature"];
            break;
    }
    
    NSMutableArray *oauthHeaders = [NSMutableArray array];

    // Fill the authorization header array
    for (NSString *key in _oAuthValues) {
        NSString *obj = [_oAuthValues objectForKey:key];
        if (obj && ![obj isEqualToString:@""]) {
            [oauthHeaders addObject:[NSString stringWithFormat:@"%@=\"%@\"", [key mk_urlEncodedString], [obj mk_urlEncodedString]]];
        }
    }
    
    // Set the Authorization header
    NSString *oauthData = [NSString stringWithFormat:@"OAuth %@", [oauthHeaders componentsJoinedByString:@", "]];
    NSDictionary *oauthHeader = [NSDictionary dictionaryWithObjectsAndKeys:oauthData, @"Authorization", nil];
    
    // Add the Authorization header to the request
    [request addHeaders:oauthHeader];
}

- (void)enqueueSignedOperation:(MKNetworkOperation *)op
{
    // Sign and Enqueue the operation
    [self signRequest:op];
    [self enqueueOperation:op];
}

- (NSString *)generateXOAuthStringForURL:(NSString *)url method:(NSString *)method
{
    NSAssert(_oAuthValues && self.consumerKey && self.consumerSecret, @"Please use an initializer with Consumer Key and Consumer Secret.");
    
    // Generate timestamp and nonce values
    [self setOAuthValue:[NSString stringWithFormat:@"%ld", time(NULL)] forKey:@"oauth_timestamp"];
    [self setOAuthValue:[NSString mk_uniqueString] forKey:@"oauth_nonce"];
    
    // Construct the signature base string
    NSString *baseString = [self signatureBaseStringForURL:url method:method parameters:nil];
    
    // Generate the signature
    switch (_signatureMethod) {
        case RSOAuthHMAC_SHA1:
            [self setOAuthValue:[self generateHMAC_SHA1SignatureFor:baseString] forKey:@"oauth_signature"];
            break;
        default:
            [self setOAuthValue:[self generatePlaintextSignatureFor:baseString] forKey:@"oauth_signature"];
            break;
    }
    
    NSMutableArray *oauthHeaders = [NSMutableArray array];
    
    // Fill the authorization header array
    for (NSString *key in _oAuthValues) {
        NSString *obj = [_oAuthValues objectForKey:key];
        if (obj && ![obj isEqualToString:@""]) {
            [oauthHeaders addObject:[NSString stringWithFormat:@"%@=\"%@\"", [key mk_urlEncodedString], [obj mk_urlEncodedString]]];
        }
    }
    
    // Set the XOAuth String
    NSString *xOAuthString = [NSString stringWithFormat:@"%@ %@ %@", [method uppercaseString], url, [oauthHeaders componentsJoinedByString:@","]];
    
    // Base64-encode the string with no line wrap
    size_t outputLength;
    NSData *stringData = [xOAuthString dataUsingEncoding:NSUTF8StringEncoding];
    char *outputBuffer = MKBase64Encode([stringData bytes], [stringData length], false, &outputLength);
    NSString *finalString = [[NSString alloc] initWithBytes:outputBuffer length:outputLength encoding:NSASCIIStringEncoding];
    free(outputBuffer);
    
    return finalString;
}

@end
