//
//  RNFSManager.m
//  RNFSManager
//
//  Created by Johannes Lumpe on 08/05/15.
//  Copyright (c) 2015 Johannes Lumpe. All rights reserved.
//

#import "RNFSManager.h"
#import "RCTBridge.h"
#import "NSArray+Map.h"
#import "Downloader.h"
#import "Uploader.h"
#import "RCTEventDispatcher.h"

@implementation RNFSManager

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue
{
  return dispatch_queue_create("pe.lum.rnfs", DISPATCH_QUEUE_SERIAL);
}

RCT_EXPORT_METHOD(readDir:(NSString *)dirPath
                  callback:(RCTResponseSenderBlock)callback)
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error = nil;

  NSArray *contents = [fileManager contentsOfDirectoryAtPath:dirPath error:&error];

  contents = [contents rnfs_mapObjectsUsingBlock:^id(NSString *obj, NSUInteger idx) {
    NSString *path = [dirPath stringByAppendingPathComponent:obj];
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];

    return @{
      @"name": obj,
      @"path": path,
      @"size": [attributes objectForKey:NSFileSize],
      @"type": [attributes objectForKey:NSFileType]
    };
  }];

  if (error) {
    return callback([self makeErrorPayload:error]);
  }

  callback(@[[NSNull null], contents]);
}

RCT_EXPORT_METHOD(stat:(NSString *)filepath
                  callback:(RCTResponseSenderBlock)callback)
{
  NSError *error = nil;
  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filepath error:&error];

  if (error) {
    return callback([self makeErrorPayload:error]);
  }

  attributes = @{
    @"ctime": [self dateToTimeIntervalNumber:(NSDate *)[attributes objectForKey:NSFileCreationDate]],
    @"mtime": [self dateToTimeIntervalNumber:(NSDate *)[attributes objectForKey:NSFileModificationDate]],
    @"size": [attributes objectForKey:NSFileSize],
    @"type": [attributes objectForKey:NSFileType],
    @"mode": @([[NSString stringWithFormat:@"%ld", (long)[(NSNumber *)[attributes objectForKey:NSFilePosixPermissions] integerValue]] integerValue])
  };

  callback(@[[NSNull null], attributes]);
}

RCT_EXPORT_METHOD(writeFile:(NSString *)filepath
                  contents:(NSString *)base64Content
                  attributes:(NSDictionary *)attributes
                  callback:(RCTResponseSenderBlock)callback)
{
  NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Content options:NSDataBase64DecodingIgnoreUnknownCharacters];
  BOOL success = [[NSFileManager defaultManager] createFileAtPath:filepath contents:data attributes:attributes];

  if (!success) {
    return callback(@[[NSString stringWithFormat:@"Could not write file at path %@", filepath]]);
  }

  callback(@[[NSNull null], [NSNumber numberWithBool:success], filepath]);
}

RCT_EXPORT_METHOD(unlink:(NSString*)filepath
                  callback:(RCTResponseSenderBlock)callback)
{
  NSFileManager *manager = [NSFileManager defaultManager];
  BOOL exists = [manager fileExistsAtPath:filepath isDirectory:false];

  if (!exists) {
    return callback(@[[NSString stringWithFormat:@"File at path %@ does not exist", filepath]]);
  }
  NSError *error = nil;
  BOOL success = [manager removeItemAtPath:filepath error:&error];

  if (!success) {
    return callback([self makeErrorPayload:error]);
  }

  callback(@[[NSNull null], [NSNumber numberWithBool:success], filepath]);
}

RCT_EXPORT_METHOD(mkdir:(NSString*)filepath
                  excludeFromBackup:(BOOL)excludeFromBackup
                  callback:(RCTResponseSenderBlock)callback)
{
  NSFileManager *manager = [NSFileManager defaultManager];

  NSError *error = nil;
  BOOL success = [manager createDirectoryAtPath:filepath withIntermediateDirectories:YES attributes:nil error:&error];

  if (!success) {
    return callback([self makeErrorPayload:error]);
  }

  NSURL *url = [NSURL fileURLWithPath:filepath];

  success = [url setResourceValue: [NSNumber numberWithBool: excludeFromBackup] forKey: NSURLIsExcludedFromBackupKey error: &error];

  if (!success) {
    return callback([self makeErrorPayload:error]);
  }

  callback(@[[NSNull null], [NSNumber numberWithBool:success], filepath]);
}

RCT_EXPORT_METHOD(readFile:(NSString *)filepath
                  callback:(RCTResponseSenderBlock)callback)
{
  NSData *content = [[NSFileManager defaultManager] contentsAtPath:filepath];
  NSString *base64Content = [content base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed];

  if (!base64Content) {
    return callback(@[[NSString stringWithFormat:@"Could not read file at path %@", filepath]]);
  }

  callback(@[[NSNull null], base64Content]);
}

RCT_EXPORT_METHOD(downloadFile:(NSString *)urlStr
                  filepath:(NSString *)filepath
                  jobId:(nonnull NSNumber *)jobId
                  headers:(NSString *)headers
                  callback:(RCTResponseSenderBlock)callback)
{

  DownloaderCallback downloaderSuccessCallback = ^(NSNumber* statusCode, NSNumber* contentLength, NSNumber* bytesWritten) {
    return callback(@[[NSNull null], [NSNumber numberWithBool:YES], filepath]);
  };

  ErrorCallback downloaderErrorCallback = ^(NSError* error) {
    return callback([self makeErrorPayload:error]);
  };

  DownloaderCallback downloaderProgressCallback = ^(NSNumber* statusCode, NSNumber* contentLength, NSNumber* bytesWritten) {
    [self.bridge.eventDispatcher sendAppEventWithName:[NSString stringWithFormat:@"DownloadProgress-%@", jobId]
                                                 body:@{@"statusCode": statusCode,
                                                        @"contentLength": contentLength,
                                                        @"bytesWritten": bytesWritten}];
  };

  Downloader* downloader = [Downloader alloc];

  [downloader downloadFile:urlStr toFile:filepath withHeaders:headers callback:downloaderSuccessCallback errorCallback:downloaderErrorCallback progressCallback:downloaderProgressCallback];
}

RCT_EXPORT_METHOD(uploadFile:(NSString *)filepath
                  urlStr:(NSString *)urlStr
                  attachmentName:(NSString *)attachmentName
                  attachmentFileName:(NSString *)attachmentFileName
                  jobId:(nonnull NSNumber *)jobId
                  headers:(NSString *)headers
                  callback:(RCTResponseSenderBlock)callback)
{
  
  UploaderDoneCallback successCallback = ^(NSNumber* statusCode, NSData* response) {
    NSString* respStr = [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
    return callback(@[[NSNull null], [NSNumber numberWithBool:YES], respStr]);
  };
  
  ErrorCallback errorCallback = ^(NSError* error) {
    return callback([self makeErrorPayload:error]);
  };
  
  UploaderCallback progressCallback = ^(NSNumber* statusCode, NSNumber* contentLength, NSNumber* bytesWritten) {
    [self.bridge.eventDispatcher sendAppEventWithName:[NSString stringWithFormat:@"UploadProgress-%@", jobId]
                                                 body:@{@"statusCode": statusCode,
                                                        @"contentLength": contentLength,
                                                        @"bytesWritten": bytesWritten}];
  };
  
  Uploader* uploader = [Uploader alloc];
  
  [uploader uploadFile:filepath
                urlStr:urlStr
        attachmentName:attachmentName
    attachmentFileName:attachmentFileName
               headers:headers
              callback:successCallback
         errorCallback:errorCallback
      progressCallback:progressCallback];
}

RCT_EXPORT_METHOD(pathForBundle:(NSString *)bundleNamed
                  callback:(RCTResponseSenderBlock)callback)
{
    NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingFormat:@"/%@.bundle", bundleNamed];
    NSBundle *bundle = [NSBundle bundleWithPath:path];

    if (!bundle) {
        bundle = [NSBundle bundleForClass:NSClassFromString(bundleNamed)];
        path = bundle.bundlePath;
    }

    if (!bundle.isLoaded) {
        [bundle load];
    }

    if (path) {
        callback(@[[NSNull null], path]);
    } else {
        callback(@[[NSError errorWithDomain:NSPOSIXErrorDomain
                                       code:NSFileNoSuchFileError
                                   userInfo:nil].localizedDescription,
                   [NSNull null]]);
    }
}

RCT_EXPORT_METHOD(rename:(NSString*)filepath
             destination:(NSString*)destination
                callback:(RCTResponseSenderBlock)callback)
{
  return callback(@[@{
      @"description": @"Rename not supported on iOS!!!",
      @"code": @(1337)
      }]);
}

- (NSNumber *)dateToTimeIntervalNumber:(NSDate *)date
{
  return @([date timeIntervalSince1970]);
}

- (NSArray *)makeErrorPayload:(NSError *)error
{
  return @[@{
    @"description": error.localizedDescription,
    @"code": @(error.code)
  }];
}

- (NSString *)getPathForDirectory:(int)directory
{
  NSArray *paths = NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES);
  return [paths firstObject];
}

- (NSDictionary *)constantsToExport
{
  return @{
    @"MainBundlePath": [[NSBundle mainBundle] bundlePath],
    @"NSCachesDirectoryPath": [self getPathForDirectory:NSCachesDirectory],
    @"NSDocumentDirectoryPath": [self getPathForDirectory:NSDocumentDirectory],
    @"NSFileTypeRegular": NSFileTypeRegular,
    @"NSFileTypeDirectory": NSFileTypeDirectory
  };
}

@end
