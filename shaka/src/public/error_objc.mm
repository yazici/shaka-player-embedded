// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "shaka/error_objc.h"

#include "shaka/error.h"
#include "src/util/objc_utils.h"

@interface ShakaPlayerError () {
}

@end

@implementation ShakaPlayerError

@synthesize message;
@synthesize category;
@synthesize code;
@synthesize severity;

- (instancetype)init {
  if ((self = [super init])) {
    message = @"";
    category = 0;
    code = 0;
    severity = 0;
  }
  return self;
}

- (instancetype)initWithMessage:(NSString *)message {
  if ((self = [self init])) {
    self.message = message;
  }
  return self;
}

- (instancetype)initWithError:(const shaka::Error &)error {
  if ((self = [super init])) {
    message = shaka::util::ObjcConverter<std::string>::ToObjc(error.message);
    category = error.category;
    code = error.code;
    severity = error.severity;
  }
  return self;
}

@end
