//
//  CASParser.m
//  Classy
//
//  Created by Jonas Budelmann on 15/09/13.
//  Copyright (c) 2013 cloudling. All rights reserved.
//

#import "CASParser.h"
#import "CASLexer.h"
#import "CASStyleNode.h"
#import "CASToken.h"
#import "CASLog.h"
#import "CASStyleProperty.h"
#import "CASStyleSelector.h"
#import "NSString+CASAdditions.h"

NSString * const CASParseFailingFilePathErrorKey = @"CASParseFailingFilePathErrorKey";
NSInteger const CASParseErrorFileContents = 2;

@interface CASParser ()

@property (nonatomic, strong) CASLexer *lexer;
@property (nonatomic, strong) NSMutableArray *styleSelectors;
@property (nonatomic, strong) NSMutableDictionary *styleVars;

@end

@implementation CASParser

+ (NSArray *)stylesFromFilePath:(NSString *)filePath error:(NSError **)error {
    NSError *fileError = nil;
    NSString *contents = [NSString stringWithContentsOfFile:filePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&fileError];
    if (!contents || fileError) {
        NSMutableDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Could not parse file",
            NSLocalizedFailureReasonErrorKey: @"File does not exist or is empty",
            CASParseFailingFilePathErrorKey : filePath ?: @""
        }.mutableCopy;

        if (fileError) {
            [userInfo setObject:fileError forKey:NSUnderlyingErrorKey];
        }

        if (error) {
            *error = [NSError errorWithDomain:CASParseErrorDomain code:CASParseErrorFileContents userInfo:userInfo];
        }
        
        return nil;
    }

    CASLog(@"Start parsing file \n%@", filePath);
    NSError *parseError = nil;
    NSArray *styles = [self stylesFromString:contents error:&parseError];
    if (parseError) {
        NSMutableDictionary *userInfo = parseError.userInfo.mutableCopy;
        [userInfo addEntriesFromDictionary:@{ CASParseFailingFilePathErrorKey : filePath }];
        if (error) {
            *error = [NSError errorWithDomain:parseError.domain code:parseError.code userInfo:userInfo];
        }
        return nil;
    }

    return styles;
}

+ (NSArray *)stylesFromString:(NSString *)string error:(NSError **)error {
    CASParser *parser = CASParser.new;
    NSError *parseError = nil;
    NSArray *styles = [parser parseString:string error:&parseError];

    if (parseError) {
        if (error) {
            *error = parseError;
        }
        return nil;
    }
    if (!styles.count) {
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"Could not parse string",
            NSLocalizedFailureReasonErrorKey: @"Could not find any styles"
        };
        if (error) {
            *error = [NSError errorWithDomain:CASParseErrorDomain code:CASParseErrorFileContents userInfo:userInfo];
        }
        return nil;
    }
    
    return styles;
}

- (NSArray *)parseString:(NSString *)string error:(NSError **)error {
    self.lexer = [[CASLexer alloc] initWithString:string];
    self.styleSelectors = NSMutableArray.new;
    self.styleVars = NSMutableDictionary.new;

    NSArray *currentNodes = nil;
    while (self.peekToken.type != CASTokenTypeEOS) {
        if (self.lexer.error) {
            if (error) {
                *error = self.lexer.error;
            }
            return nil;
        }

        CASStyleProperty *styleVar = [self nextStyleVar];
        if (styleVar) {
            if (currentNodes.count) {
                //TODO error can't have vars inside styleNOdes
            }
            [styleVar resolveExpressions];
            self.styleVars[styleVar.nameToken.value] = styleVar;
            [self consumeTokensMatching:^BOOL(CASToken *token) {
                return token.isWhitespace || token.type == CASTokenTypeSemiColon;
            }];
            continue;
        }

        NSArray *styleNodes = [self nextStyleNodes];
        if (styleNodes.count) {
            currentNodes = styleNodes;
            [self consumeTokenOfType:CASTokenTypeLeftCurlyBrace];
            [self consumeTokenOfType:CASTokenTypeIndent];
            continue;
        }

        // not a style group therefore must be a property
        CASStyleProperty *styleProperty = [self nextStyleProperty];
        if (styleProperty) {
            if (!currentNodes.count) {
                if (error) {
                    *error = [self.lexer errorWithDescription:@"Invalid style property"
                                                       reason:@"Needs to be within a style node"
                                                         code:CASParseErrorFileContents];
                }
                return nil;
            }
            [styleProperty resolveExpressions];
            for (CASStyleNode *node in currentNodes) {
                [node addStyleProperty:styleProperty];
            }
            continue;
        }

        BOOL closeNode = [self consumeTokensMatching:^BOOL(CASToken *token) {
            return token.type == CASTokenTypeOutdent || token.type == CASTokenTypeRightCurlyBrace;
        }];
        if (closeNode) {
            currentNodes = nil;
        }

        BOOL acceptableToken = [self consumeTokensMatching:^BOOL(CASToken *token) {
            return token.isWhitespace || token.type == CASTokenTypeSemiColon;
        }];
        if (!acceptableToken && !closeNode) {
            NSString *description = [NSString stringWithFormat:@"Unexpected token `%@`", self.nextToken];
            if (error) {
                *error = [self.lexer errorWithDescription:description
                                                   reason:@"Token does not belong in current context"
                                                     code:CASParseErrorFileContents];
            }
            return nil;
        }
    }

    return self.styleSelectors;
}

#pragma mark - token helpers

- (CASToken *)peekToken {
    return self.lexer.peekToken;
}

- (CASToken *)nextToken {
    CASToken *token = self.lexer.nextToken;
    return token;
}

- (CASToken *)lookaheadByCount:(NSUInteger)count {
    return [self.lexer lookaheadByCount:count];
}

- (CASToken *)consumeTokenOfType:(CASTokenType)type {
    if (type == self.peekToken.type) {
        // return token and remove from stack
        return self.nextToken;
    }
    return nil;
}

- (BOOL)consumeTokensMatching:(BOOL(^)(CASToken *token))matchBlock {
    BOOL anyMatches = NO;
    while (matchBlock(self.peekToken)) {
        anyMatches = YES;
        [self nextToken];
    }
    return anyMatches;
}

#pragma mark - nodes

- (CASStyleProperty *)nextStyleVar {
    // variable if following seq: CASTokenTypeRef, `=`, any token until newline
    NSInteger i = 1;
    CASToken *token = [self lookaheadByCount:i];
    BOOL hasEqualsSign = NO;
    CASToken *refToken;

    while (token && token.isPossiblyVar && !(hasEqualsSign && refToken)) {
        if (token.type == CASTokenTypeRef) {
            refToken = token;
        }
        if (refToken && [token valueIsEqualTo:@"="]) {
            hasEqualsSign = YES;
        }
        token = [self lookaheadByCount:++i];
    }

    if ([refToken.value hasPrefix:@"@"]) {
        //TODO error `@` is reserved for property lookup
    }

    if (hasEqualsSign && refToken) {
        // consume LHS of var
        while (--i >= 0) {
            [self nextToken];
        }

        // collect value tokens, enclose in ()
        NSMutableArray *valueTokens = NSMutableArray.new;
        [valueTokens addObject:[CASToken tokenOfType:CASTokenTypeLeftRoundBrace]];
        while (token.type != CASTokenTypeNewline && token.type != CASTokenTypeSemiColon) {
            [valueTokens addObject:token];
            token = [self nextToken];
        }
        [valueTokens addObject:[CASToken tokenOfType:CASTokenTypeRightRoundBrace]];

        return [[CASStyleProperty alloc] initWithNameToken:refToken valueTokens:valueTokens];
    }
    return nil;
}

- (NSArray *)nextStyleNodes {
    NSInteger i = 1;
    CASToken *token = [self lookaheadByCount:i];
    while (token && token.isPossiblySelector) {
        token = [self lookaheadByCount:++i];
    }

    if (token.type != CASTokenTypeLeftCurlyBrace && token.type != CASTokenTypeIndent) {
        return nil;
    }

    NSMutableArray *styleNodes = NSMutableArray.new;
    CASStyleSelector *styleSelector;
    CASToken *previousToken, *argNameToken, *argValueToken;
    token = nil;
    BOOL shouldSelectSubclasses = NO;
    BOOL shouldSelectDescendants = YES;
    BOOL argumentListMode = NO;

    while (--i > 0) {
        previousToken = token;
        token = [self nextToken];

        if (argumentListMode) {
            // TODO refactor
            if (token.type == CASTokenTypeRightSquareBrace) {
                argumentListMode = NO;
            } else if (token.type == CASTokenTypeSelector || token.type == CASTokenTypeRef) {
                if (!argNameToken) {
                    argNameToken = token;
                } else if (!argValueToken) {
                    argValueToken = token;
                }

                if (argNameToken && argValueToken) {
                    [styleSelector setArgumentValue:argValueToken forName:argNameToken];
                    argValueToken = nil;
                    argNameToken = nil;
                }
            }
            continue;
        }

        if (token.type == CASTokenTypeCarat) {
            shouldSelectSubclasses = YES;
        } else if (token.type == CASTokenTypeRef || token.type == CASTokenTypeSelector) {
            NSString *tokenValue = [token.value cas_stringByTrimmingWhitespace];

            BOOL shouldSpawn = ![tokenValue hasPrefix:@"."]
                                || styleSelector == nil
                                || previousToken.isWhitespace
                                || [previousToken valueIsEqualTo:@">"];

            if (shouldSpawn) {
                if (styleSelector) {
                    CASStyleSelector *childSelector = CASStyleSelector.new;
                    styleSelector.shouldSelectDescendants = shouldSelectDescendants;
                    styleSelector.childSelector = childSelector;

                    styleSelector = childSelector;
                } else {
                    styleSelector = CASStyleSelector.new;
                }
            }

            styleSelector.shouldSelectSubclasses = shouldSelectSubclasses;
            
            // TODO error if viewClass is nil

            if ([tokenValue hasPrefix:@"."]) {
                styleSelector.styleClass = [tokenValue substringFromIndex:1];
            } else {
                styleSelector.viewClass = NSClassFromString(tokenValue);
            }

            // reset state
            shouldSelectSubclasses = NO;
            shouldSelectDescendants = YES;
        } else if (token.type == CASTokenTypeLeftSquareBrace) {
            argumentListMode = YES;
        } else if([token valueIsEqualTo:@">"]) {
            shouldSelectDescendants = NO;
        } else if ([token valueIsEqualTo:@","]) {
            if (styleSelector) {
                [styleNodes addObject:CASStyleNode.new];
                styleSelector.node = styleNodes.lastObject;
                [self.styleSelectors addObject:styleSelector];
            }
            styleSelector = nil;
        }
    }
    if (styleSelector) {
        [styleNodes addObject:CASStyleNode.new];
        styleSelector.node = styleNodes.lastObject;
        [self.styleSelectors addObject:styleSelector];
    }
    
    return styleNodes;
}

- (CASStyleProperty *)nextStyleProperty {
    NSInteger i = 1;
    CASToken *nameToken;
    NSMutableArray *valueTokens = NSMutableArray.new;

    CASToken *token = [self lookaheadByCount:i];
    while (token && token.type != CASTokenTypeNewline
           && token.type != CASTokenTypeLeftCurlyBrace
           && token.type != CASTokenTypeRightCurlyBrace
           && token.type != CASTokenTypeOutdent
           && token.type != CASTokenTypeSemiColon
           && token.type != CASTokenTypeEOS) {

        if (token.type == CASTokenTypeSpace
            || token.type == CASTokenTypeIndent
            || [token valueIsEqualTo:@":"]) {
            token = [self lookaheadByCount:++i];
            continue;
        }

        if (!nameToken) {
            nameToken = token;
        } else {
            if (token.type == CASTokenTypeRef) {
                CASStyleProperty *styleVar = self.styleVars[token.value];
                if (styleVar) {
                    [valueTokens addObjectsFromArray:styleVar.valueTokens];
                } else {
                    [valueTokens addObject:token];
                }
            } else {
                [valueTokens addObject:token];
            }
        }
        token = [self lookaheadByCount:++i];
    }

    if (nameToken.value && valueTokens.count) {
        // consume tokens
        while (--i > 0) {
            [self nextToken];
        }
        return [[CASStyleProperty alloc] initWithNameToken:nameToken valueTokens:valueTokens];
    }

    return nil;
}

@end