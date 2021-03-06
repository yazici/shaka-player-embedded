// Copyright 2018 Google LLC
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

#import "shaka/ShakaPlayerView.h"

#include "shaka/js_manager.h"
#include "shaka/media/sdl_audio_renderer.h"
#include "shaka/player.h"
#include "shaka/utils.h"
#include "shaka/video.h"

#include "src/js/manifest+Internal.h"
#include "src/js/player_externs+Internal.h"
#include "src/js/stats+Internal.h"
#include "src/js/track+Internal.h"
#include "src/media/ios/ios_video_renderer.h"
#include "src/public/ShakaPlayerView+Internal.h"
#include "src/public/error_objc+Internal.h"
#include "src/util/macros.h"
#include "src/util/objc_utils.h"

#define ShakaRenderLoopDelay (1.0 / 60)


namespace {

BEGIN_ALLOW_COMPLEX_STATICS
static std::weak_ptr<shaka::JsManager> gJsEngine;
END_ALLOW_COMPLEX_STATICS

class NativeClient final : public shaka::Player::Client, public shaka::Video::Client {
 public:
  NativeClient() {}

  void OnError(const shaka::Error &error) override {
    ShakaPlayerError *objc_error = [[ShakaPlayerError alloc] initWithError:error];
    shaka::util::DispatchObjcEvent(_client, @selector(onPlayerError:), objc_error);
  }

  void OnBuffering(bool is_buffering) override {
    shaka::util::DispatchObjcEvent(_client, @selector(onPlayerBufferingChange:), is_buffering);
  }

  void OnPlaying() override {
    shaka::util::DispatchObjcEvent(_client, @selector(onPlayerPlayingEvent));
  }

  void OnPause() override {
    shaka::util::DispatchObjcEvent(_client, @selector(onPlayerPauseEvent));
  }

  void OnEnded() override {
    shaka::util::DispatchObjcEvent(_client, @selector(onPlayerEndedEvent));
  }


  void OnSeeking() override {
    shaka::util::DispatchObjcEvent(_client, @selector(onPlayerSeekingEvent));
  }

  void OnSeeked() override {
    shaka::util::DispatchObjcEvent(_client, @selector(onPlayerSeekedEvent));
  }


  void SetClient(id<ShakaPlayerClient> client) {
    _client = client;
  }

 private:
  __weak id<ShakaPlayerClient> _client;
};

}  // namespace

std::shared_ptr<shaka::JsManager> ShakaGetGlobalEngine() {
  std::shared_ptr<shaka::JsManager> ret = gJsEngine.lock();
  if (!ret) {
    shaka::JsManager::StartupOptions options;
    options.static_data_dir = "Frameworks/ShakaPlayerEmbedded.framework";
    options.dynamic_data_dir = std::string(getenv("HOME")) + "/Library";
    options.is_static_relative_to_bundle = true;
    ret.reset(new shaka::JsManager(options));
    gJsEngine = ret;
  }
  return ret;
}

@interface ShakaPlayerView () {
  NativeClient _client;
  shaka::media::ios::IosVideoRenderer _video_renderer;
  shaka::media::SdlAudioRenderer *_audio_renderer;

  shaka::Video *_video;
  shaka::Player *_player;
  NSTimer *_renderLoopTimer;
  CALayer *_imageLayer;
  CALayer *_textLayer;
  BOOL _remakeTextLayer;
  std::shared_ptr<shaka::JsManager> _engine;
}

@end

@implementation ShakaPlayerView

// MARK: setup

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    if (![self setup])
      return nil;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  if ((self = [super initWithCoder:aDecoder])) {
    if (![self setup])
      return nil;
  }
  return self;
}

- (instancetype)initWithClient:(id<ShakaPlayerClient>)client {
  if ((self = [super init])) {
    // super.init calls self.initWithFrame, so this doesn't need to setup again.
    if (![self setClient:client])
      return nil;
  }
  return self;
}

- (void)dealloc {
  delete _player;
  delete _video;
  delete _audio_renderer;
}

- (BOOL)setup {
  // Set up the image layer.
  _imageLayer = [CALayer layer];
  [self.layer addSublayer:_imageLayer];

  // Set up the text layer.
  _textLayer = [CALayer layer];
  [self.layer addSublayer:_textLayer];

  // Disable default animations.
  _imageLayer.actions = @{@"position": [NSNull null], @"bounds": [NSNull null]};

  return YES;
}

- (BOOL)setClient:(id<ShakaPlayerClient>)client {
  _client.SetClient(client);
  if (_engine) {
    return YES;
  }

  // Create JS objects.
  _engine = ShakaGetGlobalEngine();
  _video = new shaka::Video(_engine.get());
  _player = new shaka::Player(_engine.get());
  _audio_renderer = new shaka::media::SdlAudioRenderer("");

  // Set up video.
  _remakeTextLayer = NO;
  _video->Initialize(&_client, &_video_renderer, _audio_renderer);

  // Set up player.
  const auto initResults = _player->Initialize(_video, &_client);
  if (initResults.has_error()) {
    _client.OnError(initResults.error());
    return NO;
  }
  return YES;
}

- (void)checkInitialized {
  if (!_engine) {
    [NSException raise:NSGenericException format:@"Must call setClient to initialize the object"];
  }
}

// MARK: rendering

- (void)renderLoop:(NSTimer *)timer {
  @synchronized(self) {
    if (CGImageRef image = _video_renderer.Render()) {
      _imageLayer.contents = (__bridge_transfer id)image;

      // Fit image in frame.
      shaka::ShakaRect image_bounds = {0, 0, CGImageGetWidth(image), CGImageGetHeight(image)};
      shaka::ShakaRect dest_bounds = {
          0,
          0,
          static_cast<int>(self.bounds.size.width),
          static_cast<int>(self.bounds.size.height),
      };
      shaka::ShakaRect src;
      shaka::ShakaRect dest;
      shaka::FitVideoToRegion(image_bounds, dest_bounds, _video_renderer.fill_mode(), &src, &dest);
      _imageLayer.contentsRect = CGRectMake(static_cast<CGFloat>(src.x) / image_bounds.w,
                                            static_cast<CGFloat>(src.y) / image_bounds.h,
                                            static_cast<CGFloat>(src.w) / image_bounds.w,
                                            static_cast<CGFloat>(src.h) / image_bounds.h);
      _imageLayer.frame = CGRectMake(dest.x, dest.y, dest.w, dest.h);
    }

    if (self.closedCaptions) {
      BOOL sizeChanged = _textLayer.frame.size.width != _imageLayer.frame.size.width ||
                         _textLayer.frame.size.height != _imageLayer.frame.size.height;

      _textLayer.hidden = NO;
      _textLayer.frame = _imageLayer.frame;

      if (_remakeTextLayer || sizeChanged) {
        // Remake text cues, since either they changed or the size of the bounds changed.
        [self remakeTextCues];
        _remakeTextLayer = NO;
      }
    } else {
      _textLayer.hidden = YES;
    }
  }
}

- (void)remakeTextCues {
  auto text_tracks = _video->TextTracks();
  auto cues = text_tracks[0].cues();

  // TODO: Once activeCues is implemented, use that instead.
  // TODO: This could be more efficient if I take advantage of how the cues are
  // guaranteed to be sorted, so I can safely stop once the cues overtake the
  // time.
  double time = self.currentTime;
  auto callback = [time](shaka::VTTCue *cue) {
    return cue->startTime() <= time && cue->endTime() > time;
  };
  auto begin = cues.begin();
  auto end = cues.end();
  std::vector<shaka::VTTCue *> activeCues;
  std::copy_if(begin, end, std::back_inserter(activeCues), callback);

  // TODO: Try recycling old text layers which contain the correct text contents.
  // This will make the layers do a move animation instead of a fade animation when appropriate,
  // and also might be more performant.
  for (CALayer *layer in [_textLayer.sublayers copy])
    [layer removeFromSuperlayer];

  // Use the system font for body. The ensures that if the user changes their font size, it will use
  // that font size.
  UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];

  // Create CATextLayers for cues.
  NSMutableArray<CATextLayer *> *cueLayers = [NSMutableArray array];
  for (unsigned long i = 0; i < activeCues.size(); i++) {
    // Read the cues in inverse order, so the oldest cue is at the bottom.
    shaka::VTTCue *cue = activeCues[activeCues.size() - i - 1];
    NSString *cueText = [NSString stringWithUTF8String:cue->text().c_str()];

    for (NSString *line in [cueText componentsSeparatedByString:@"\n"]) {
      CATextLayer *cueLayer = [[CATextLayer alloc] init];
      cueLayer.string = line;
      cueLayer.font = CGFontCreateWithFontName(static_cast<CFStringRef>(font.fontName));
      cueLayer.fontSize = font.pointSize;
      cueLayer.backgroundColor = [UIColor blackColor].CGColor;
      cueLayer.foregroundColor = [UIColor whiteColor].CGColor;
      cueLayer.alignmentMode = kCAAlignmentCenter;

      // TODO: Take into account direction setting, snap to lines, position align, etc.

      // Determine size of cue line.
      CGFloat width = static_cast<CGFloat>(cue->size() * (_textLayer.bounds.size.width) * 0.01);
      NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin;
      // TODO: Sometimes, if the system font size is set high, this will make very wrong estimates.
      CGSize effectiveSize = [line boundingRectWithSize:CGSizeMake(width, 9999)
                                                options:options
                                             attributes:@{NSFontAttributeName: font}
                                                context:nil]
                                 .size;
      // The size estimates don't always seem to be 100% accurate, so this adds a bit to the width.
      width = ceil(effectiveSize.width) + 16;
      CGFloat height = ceil(effectiveSize.height);
      CGFloat x = (_textLayer.bounds.size.width - width) * 0.5f;
      cueLayer.frame = CGRectMake(x, 0, width, height);

      [cueLayers addObject:cueLayer];
      [_textLayer addSublayer:cueLayer];
    }
  }

  // Determine y positions for the CATextLayers.
  CGFloat y = _textLayer.bounds.size.height;
  for (unsigned long i = 0; i < cueLayers.count; i++) {
    // Read the cue layers in inverse order, since they are being drawn from the bottom up.
    CATextLayer *cueLayer = cueLayers[cueLayers.count - i - 1];

    CGSize size = cueLayer.frame.size;
    y -= size.height;
    cueLayer.frame = CGRectMake(cueLayer.frame.origin.x, y, size.width, size.height);
  }
}

// MARK: controls

- (void)play {
  [self checkInitialized];
  _video->Play();
}

- (void)pause {
  [self checkInitialized];
  _video->Pause();
}

- (BOOL)paused {
  [self checkInitialized];
  return _video->Paused();
}

- (BOOL)ended {
  [self checkInitialized];
  return _video->Ended();
}

- (BOOL)seeking {
  [self checkInitialized];
  return _video->Seeking();
}

- (double)duration {
  [self checkInitialized];
  return _video->Duration();
}

- (double)playbackRate {
  [self checkInitialized];
  return _video->PlaybackRate();
}

- (void)setPlaybackRate:(double)rate {
  [self checkInitialized];
  _video->SetPlaybackRate(rate);
}

- (double)currentTime {
  [self checkInitialized];
  return _video->CurrentTime();
}

- (void)setCurrentTime:(double)time {
  [self checkInitialized];
  _video->SetCurrentTime(time);
}

- (double)volume {
  [self checkInitialized];
  return _video->Volume();
}

- (void)setVolume:(double)volume {
  [self checkInitialized];
  _video->SetVolume(volume);
}

- (BOOL)muted {
  [self checkInitialized];
  return _video->Muted();
}

- (void)setMuted:(BOOL)muted {
  [self checkInitialized];
  _video->SetMuted(muted);
}


- (ShakaPlayerLogLevel)logLevel {
  [self checkInitialized];
  const auto results = shaka::Player::GetLogLevel(_engine.get());
  if (results.has_error())
    return ShakaPlayerLogLevelNone;
  else
    return static_cast<ShakaPlayerLogLevel>(results.results());
}

- (void)setLogLevel:(ShakaPlayerLogLevel)logLevel {
  [self checkInitialized];
  auto castedLogLevel = static_cast<shaka::Player::LogLevel>(logLevel);
  const auto results = shaka::Player::SetLogLevel(_engine.get(), castedLogLevel);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (NSString *)playerVersion {
  [self checkInitialized];
  const auto results = shaka::Player::GetPlayerVersion(_engine.get());
  if (results.has_error())
    return @"unknown version";
  else
    return [NSString stringWithCString:results.results().c_str()];
}


- (BOOL)isAudioOnly {
  [self checkInitialized];
  auto results = _player->IsAudioOnly();
  if (results.has_error())
    return false;
  else
    return results.results();
}

- (BOOL)isLive {
  [self checkInitialized];
  auto results = _player->IsLive();
  if (results.has_error())
    return false;
  else
    return results.results();
}

- (BOOL)closedCaptions {
  [self checkInitialized];
  auto results = _player->IsTextTrackVisible();
  if (results.has_error())
    return false;
  else
    return results.results();
}

- (void)setClosedCaptions:(BOOL)closedCaptions {
  [self checkInitialized];
  _player->SetTextTrackVisibility(closedCaptions);
}

- (ShakaBufferedRange *)seekRange {
  [self checkInitialized];
  auto results = _player->SeekRange();
  if (results.has_error()) {
    _client.OnError(results.error());
    return [[ShakaBufferedRange alloc] init];
  } else {
    return [[ShakaBufferedRange alloc] initWithCpp:results.results()];
  }
}

- (ShakaBufferedInfo *)bufferedInfo {
  [self checkInitialized];
  auto results = _player->GetBufferedInfo();
  if (results.has_error()) {
    _client.OnError(results.error());
    return [[ShakaBufferedInfo alloc] init];
  } else {
    return [[ShakaBufferedInfo alloc] initWithCpp:results.results()];
  }
}


- (ShakaStats *)getStats {
  [self checkInitialized];
  auto results = _player->GetStats();
  if (results.has_error()) {
    _client.OnError(results.error());
    return [[ShakaStats alloc] init];
  } else {
    return [[ShakaStats alloc] initWithCpp:results.results()];
  }
}

- (NSArray<ShakaTrack *> *)getTextTracks {
  [self checkInitialized];
  auto results = _player->GetTextTracks();
  if (results.has_error())
    return [[NSArray<ShakaTrack *> alloc] init];
  else
    return shaka::util::ObjcConverter<std::vector<shaka::Track>>::ToObjc(results.results());
}

- (NSArray<ShakaTrack *> *)getVariantTracks {
  [self checkInitialized];
  auto results = _player->GetVariantTracks();
  if (results.has_error())
    return [[NSArray<ShakaTrack *> alloc] init];
  else
    return shaka::util::ObjcConverter<std::vector<shaka::Track>>::ToObjc(results.results());
}


- (void)load:(NSString *)uri {
  return [self load:uri withStartTime:NAN];
}

- (void)load:(NSString *)uri withStartTime:(double)startTime {
  @synchronized(self) {
    [self checkInitialized];
    const auto loadResults = _player->Load(uri.UTF8String, startTime);
    if (loadResults.has_error()) {
      _client.OnError(loadResults.error());
    } else {
      [self postLoadOperations];
    }
  }
}

- (void)load:(NSString *)uri withBlock:(ShakaPlayerAsyncBlock)block {
  [self load:uri withStartTime:NAN andBlock:block];
}

- (void)load:(NSString *)uri withStartTime:(double)startTime andBlock:(ShakaPlayerAsyncBlock)block {
  [self checkInitialized];
  auto loadResults = self->_player->Load(uri.UTF8String, startTime);
  shaka::util::CallBlockForFuture(self, std::move(loadResults), ^(ShakaPlayerError *error) {
    if (!error) {
      [self postLoadOperations];
    }
    block(error);
  });
}

- (void)postLoadOperations {
  _imageLayer.contents = nil;

  // Start up the render loop.
  SEL renderLoopSelector = @selector(renderLoop:);
  _renderLoopTimer = [NSTimer scheduledTimerWithTimeInterval:ShakaRenderLoopDelay
                                                      target:self
                                                    selector:renderLoopSelector
                                                    userInfo:nullptr
                                                     repeats:YES];

  auto textTracks = _video->TextTracks();
  if (!textTracks.empty()) {
    _remakeTextLayer = YES;

    // Make a weak reference to self, to avoid a retain cycle.
    __weak ShakaPlayerView *weakSelf = self;

    // TODO: maybe this should be handled in video or player?
    auto onCueChange = [weakSelf]() {
      // To avoid changing layers on a background thread, do the actual cue
      // operations in the render loop.
      __strong ShakaPlayerView *strongSelf = weakSelf;
      if (strongSelf)
        strongSelf->_remakeTextLayer = YES;
    };
    textTracks[0].SetCueChangeEventListener(onCueChange);
  }
}

- (void)unloadWithBlock:(ShakaPlayerAsyncBlock)block {
  [self checkInitialized];
  // Stop the render loop before acquiring the mutex, to avoid deadlocks.
  [_renderLoopTimer invalidate];

  self->_imageLayer.contents = nil;
  for (CALayer *layer in [self->_textLayer.sublayers copy])
    [layer removeFromSuperlayer];
  auto unloadResults = self->_player->Unload();
  shaka::util::CallBlockForFuture(self, std::move(unloadResults), block);
}

- (void)configure:(const NSString *)namePath withBool:(BOOL)value {
  [self checkInitialized];
  _player->Configure(namePath.UTF8String, static_cast<bool>(value));
}

- (void)configure:(const NSString *)namePath withDouble:(double)value {
  [self checkInitialized];
  _player->Configure(namePath.UTF8String, value);
}

- (void)configure:(const NSString *)namePath withString:(const NSString *)value {
  [self checkInitialized];
  _player->Configure(namePath.UTF8String, value.UTF8String);
}

- (void)configureWithDefault:(const NSString *)namePath {
  [self checkInitialized];
  _player->Configure(namePath.UTF8String, shaka::DefaultValue);
}

- (BOOL)getConfigurationBool:(const NSString *)namePath {
  [self checkInitialized];
  auto results = _player->GetConfigurationBool(namePath.UTF8String);
  if (results.has_error()) {
    return NO;
  } else {
    return results.results();
  }
}

- (double)getConfigurationDouble:(const NSString *)namePath {
  [self checkInitialized];
  auto results = _player->GetConfigurationDouble(namePath.UTF8String);
  if (results.has_error()) {
    return 0;
  } else {
    return results.results();
  }
}

- (NSString *)getConfigurationString:(const NSString *)namePath {
  [self checkInitialized];
  auto results = _player->GetConfigurationString(namePath.UTF8String);
  if (results.has_error()) {
    return @"";
  } else {
    std::string cppString = results.results();
    return [NSString stringWithCString:cppString.c_str()];
  }
}


- (NSArray<ShakaLanguageRole *> *)audioLanguagesAndRoles {
  [self checkInitialized];
  auto results = _player->GetAudioLanguagesAndRoles();
  if (results.has_error())
    return [[NSArray<ShakaLanguageRole *> alloc] init];
  else
    return shaka::util::ObjcConverter<std::vector<shaka::LanguageRole>>::ToObjc(results.results());
}

- (NSArray<ShakaLanguageRole *> *)textLanguagesAndRoles {
  [self checkInitialized];
  auto results = _player->GetTextLanguagesAndRoles();
  if (results.has_error())
    return [[NSArray<ShakaLanguageRole *> alloc] init];
  else
    return shaka::util::ObjcConverter<std::vector<shaka::LanguageRole>>::ToObjc(results.results());
}

- (void)selectAudioLanguage:(NSString *)language withRole:(NSString *)role {
  [self checkInitialized];
  auto results = _player->SelectAudioLanguage(language.UTF8String, role.UTF8String);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (void)selectAudioLanguage:(NSString *)language {
  [self checkInitialized];
  auto results = _player->SelectAudioLanguage(language.UTF8String);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (void)selectTextLanguage:(NSString *)language withRole:(NSString *)role {
  [self checkInitialized];
  auto results = _player->SelectTextLanguage(language.UTF8String, role.UTF8String);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (void)selectTextLanguage:(NSString *)language {
  [self checkInitialized];
  auto results = _player->SelectTextLanguage(language.UTF8String);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (void)selectTextTrack:(const ShakaTrack *)track {
  [self checkInitialized];
  auto results = _player->SelectTextTrack([track toCpp]);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (void)selectVariantTrack:(const ShakaTrack *)track {
  [self checkInitialized];
  auto results = _player->SelectVariantTrack([track toCpp]);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (void)selectVariantTrack:(const ShakaTrack *)track withClearBuffer:(BOOL)clear {
  [self checkInitialized];
  auto results = _player->SelectVariantTrack([track toCpp], clear);
  if (results.has_error()) {
    _client.OnError(results.error());
  }
}

- (void)destroy {
  if (_player)
    _player->Destroy();
}

// MARK: +Internal
- (shaka::Player *)playerInstance {
  return _player;
}

@end
