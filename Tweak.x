#import "Headers.h"
#import "Utils.h"
#import "GriddyIconLocationPreferences.h"

NSMutableDictionary<NSString *, GriddyIconLocationPreferences *> *locationPrefs;
NSDictionary<NSString *, NSNumber *> *portraitSavedDict;
NSDictionary<NSString *, NSNumber *> *landscapeSavedDict;
NSMutableOrderedSet<SBIcon *> *draggedIcons;
NSArray<NSString *> *patchLocations;
BOOL isEditingLayout = NO;
CGPoint touchPoint;
long long proposedIndex = -1;
BOOL shouldRedrawList = NO;
BOOL creatingNewIcon = NO;
int screenOrientation = -1;
BOOL shouldGivePriority = YES;
NSUserDefaults *userDefaults;
CGRect gridWrapperSize;
BOOL shouldPatchFolderIcon = YES;
BOOL patchFoldersChecked = NO;
NSMutableDictionary<NSString *, NSDictionary *> *folderImageCache;
BOOL griddyImageSuccess = NO;
BOOL hasLoadedPrefs = NO;

// FIX (link error): resolve SBIcon at runtime to avoid referencing _OBJC_CLASS_$_SBIcon,
// which is not an exported symbol in SpringBoard. Original code only used `SBIcon *` as
// a type, never the class itself, so no symbol was needed.
static Class GriddySBIconClass(void) {
    static Class c = nil;
    if (!c) c = NSClassFromString(@"SBIcon");
    return c;
}

// FIX (crash): re-entrancy guard for gridCellInfoForGridSize:options:. Patching the icons
// array can indirectly re-enter layout, which re-enters this method, and the second entry
// would operate on a half-mutated array. Guard with a thread-local flag.
static __thread BOOL gInGridCellPatch = NO;

// FIX (crash): safe uniqueIdentifier access. nil / non-string / empty all return nil so
// callers can skip. Prevents nil dictionary keys and stale entries.
static NSString *GriddyIconID(SBIcon *icon) {
    if (!icon) return nil;
    @try {
        NSString *uid = icon.uniqueIdentifier;
        if ([uid isKindOfClass:[NSString class]] && uid.length > 0) return uid;
    } @catch (__unused NSException *e) {}
    return nil;
}

// FIX (crash): build a signature from cheap string lookups only (no image loading).
static NSString *GriddyFolderSignature(SBIconListModel *model) {
    if (!model) return @"";
    NSMutableString *sig = [NSMutableString string];
    NSArray *icons = nil;
    @try { icons = model.icons; } @catch (__unused NSException *e) { return @""; }
    if (![icons isKindOfClass:[NSArray class]]) return @"";
    [sig appendFormat:@"n%lu|", (unsigned long)icons.count];

    Class sbIconClass = GriddySBIconClass();
    NSUInteger previewCount = icons.count < 9 ? icons.count : 9;
    for (NSUInteger i = 0; i < previewCount; i++) {
        id obj = icons[i];
        if (!sbIconClass || ![obj isKindOfClass:sbIconClass]) { [sig appendString:@"?|"]; continue; }
        SBIcon *icon = (SBIcon *)obj;
        [sig appendFormat:@"%@|", GriddyIconID(icon) ?: @"?"];
        NSString *imgId = nil;
        if ([icon respondsToSelector:@selector(imageIdentifier)]) {
            @try { imgId = [icon performSelector:@selector(imageIdentifier)]; } @catch (__unused NSException *e) {}
        }
        if (imgId) [sig appendFormat:@"%@|", imgId];
    }
    return sig;
}

%hook SBIconListModel
%property (assign, nonatomic) BOOL griddyShouldPatch;
%property (assign, nonatomic) BOOL griddyNeedsRefreshFolderImage;

// FIX (crash): wrap the icons-array replacement so a bad return value cannot poison the
// model. Only accept a same-length NSArray; otherwise keep the original array.
- (SBIconListGridCellInfo *)gridCellInfoForGridSize:(SBHIconGridSize)arg1 options:(NSUInteger)arg2 {
    SBIconListGridCellInfo *info = %orig;
    if (!self.griddyShouldPatch) return info;
    if (gInGridCellPatch) return info;
    gInGridCellPatch = YES;
    @try {
        NSArray *originalIcons = nil;
        @try { originalIcons = self.icons; } @catch (__unused NSException *e) { originalIcons = nil; }
        if ([originalIcons isKindOfClass:[NSArray class]]) {
            NSArray *patched = patchGridCellInfoForIconList(originalIcons, info, self);
            if ([patched isKindOfClass:[NSArray class]] && patched.count == originalIcons.count) {
                self.icons = patched;
            }
        }
    } @catch (NSException *e) {
        // Never let a Griddy exception take down SpringBoard.
    }
    gInGridCellPatch = NO;
    return info;
}

- (BOOL)addIcon:(SBIcon *)icon options:(NSUInteger)arg1 {
    @try {
        if ([self.parent isKindOfClass:NSClassFromString(@"SBHLibraryCategoryFolder")] || self.gridSize.rows > 32767) return %orig;

        NSString *uid = GriddyIconID(icon);
        if (uid && !locationPrefs[uid]) {
            creatingNewIcon = YES;
            NSUInteger fallbackIndex = 0;
            NSArray *curIcons = nil;
            @try { curIcons = self.icons; } @catch (__unused NSException *e) {}
            if ([curIcons isKindOfClass:[NSArray class]]) fallbackIndex = curIcons.count;
            NSInteger chosen = ([draggedIcons containsObject:icon]) ? (NSInteger)proposedIndex : (NSInteger)fallbackIndex;
            if (chosen < 0) chosen = 0;

            if (screenOrientation == 0 && portraitSavedDict && portraitSavedDict[uid]) {
                createNewLocationPrefs(self, icon, portraitSavedDict[uid].unsignedIntegerValue);
            } else if (screenOrientation == 1 && landscapeSavedDict && landscapeSavedDict[uid]) {
                createNewLocationPrefs(self, icon, landscapeSavedDict[uid].unsignedIntegerValue);
            } else {
                createNewLocationPrefs(self, icon, (NSUInteger)chosen);
                if (locationPrefs[uid]) locationPrefs[uid].priority = 1000;
            }
        }

        if ([icon isKindOfClass:%c(SBPlaceholderIcon)] && uid) {
            [draggedIcons addObject:icon];
            if (locationPrefs[uid]) locationPrefs[uid].index = proposedIndex;
        }
    } @catch (__unused NSException *e) {}
    return %orig;
}

- (id)replaceIcon:(SBIcon *)oldIcon withIcon:(SBIcon *)newIcon options:(NSUInteger)arg2 {
    if (!self.griddyShouldPatch) return %orig;
    @try {
        NSString *oldUID = GriddyIconID(oldIcon);
        NSString *newUID = GriddyIconID(newIcon);
        if (oldUID && locationPrefs[oldUID] && newUID) {
            GriddyIconLocationPreferences *newPrefs = locationPrefs[newUID] ?: [[GriddyIconLocationPreferences alloc] init];

            if ([oldIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")] &&
                ((SBPlaceholderIcon *)oldIcon).referencedIcon.uniqueIdentifier != newIcon.uniqueIdentifier) {
                createNewLocationPrefs(self, newIcon, (NSUInteger)MAX((NSInteger)proposedIndex, 0));
            } else {
                GriddyIconLocationPreferences *oldPrefs = locationPrefs[oldUID];
                newPrefs.index = oldPrefs.index;
                newPrefs.ogIndex = oldPrefs.ogIndex;
                newPrefs.gridSize = oldPrefs.gridSize;
                locationPrefs[newUID] = newPrefs;
                if (![oldIcon isKindOfClass:NSClassFromString(@"SBWidgetIcon")]) [locationPrefs removeObjectForKey:oldUID];
            }

            if ([oldIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")]) {
                creatingNewIcon = NO;
                [locationPrefs removeObjectForKey:oldUID];
                if ([draggedIcons containsObject:oldIcon]) [draggedIcons removeObject:oldIcon];
                if ([draggedIcons count] == 0) shouldRedrawList = YES;
            }

            if ([newIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")]) newPrefs.index = proposedIndex;
        }

        if ([newIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")]) {
            if ([oldIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")] && [draggedIcons containsObject:oldIcon]) {
                [draggedIcons removeObject:oldIcon];
                if (oldUID) [locationPrefs removeObjectForKey:oldUID];
            }
            [draggedIcons addObject:newIcon];
        }
    } @catch (__unused NSException *e) {}
    return %orig;
}

- (void)removeIcon:(SBIcon *)icon options:(NSUInteger)arg1 {
    %orig;
    if (!self.griddyShouldPatch) return;
    NSString *uid = GriddyIconID(icon);
    if (isEditingLayout && uid) [locationPrefs removeObjectForKey:uid];
}

%end


%hook SBIconView

- (void)dragInteraction:(id)arg1 sessionWillBegin:(id)arg2 {
    if (!self.icon) return %orig;
    NSString *uid = GriddyIconID(self.icon);
    GriddyIconLocationPreferences *prefs = uid ? locationPrefs[uid] : nil;
    [draggedIcons removeAllObjects];

    %orig;
    if (prefs) {
        proposedIndex = prefs.index;
        prefs.ogIndex = proposedIndex;
    } else {
        proposedIndex = 0;
    }
    if (![self isKindOfClass:NSClassFromString(@"SBHLibraryCategoryPodIconView")]) [draggedIcons addObject:self.icon];
}

- (id)dragInteraction:(id)arg1 previewForLiftingItem:(id)arg2 session:(_UIDropSessionImpl *)dropSession {
    if (!self.icon) return %orig;
    id ret = %orig;
    NSString *uid = GriddyIconID(self.icon);
    GriddyIconLocationPreferences *prefs = uid ? locationPrefs[uid] : nil;
    if (!prefs) return ret;

    proposedIndex = prefs.index;
    prefs.ogIndex = proposedIndex;

    if ([draggedIcons count] == 0) {
        CGPoint touchOffset = [dropSession locationInView:self];
        if (touchOffset.x < 0) touchOffset.x = 0;
        if (touchOffset.y < 0) touchOffset.y = 0;
        if (touchOffset.x >= self.frame.size.width) touchOffset.x = self.frame.size.width-1;
        if (touchOffset.y >= self.frame.size.height) touchOffset.y = self.frame.size.height-1;

        unsigned short cols = (int)((touchOffset.x / self.frame.size.width) * prefs.gridSize.columns);
        unsigned short rows = (int)((touchOffset.y / self.frame.size.height) * prefs.gridSize.rows);
        [prefs setIndexOffsetColumns:cols rows:rows];

        if (prefs.indexOffset.columns >= prefs.gridSize.columns) {[prefs setIndexOffsetColumns:0 rows:rows];}
        if (prefs.indexOffset.rows >= prefs.gridSize.rows) {[prefs setIndexOffsetColumns:cols rows:0];}
    }

    if (![self isKindOfClass:NSClassFromString(@"SBHLibraryCategoryPodIconView")]) {
        [draggedIcons insertObject:self.icon atIndex:0];
    }
    return ret;
}

- (void)dragInteraction:(id)arg1 session:(id)arg2 willEndWithOperation:(NSUInteger)arg3 {
    [draggedIcons removeAllObjects];
    proposedIndex = -1;
    return %orig;
}

%end


%hook SBIconController

- (BOOL)iconManager:(id)arg1 canAcceptDropInSession:(_UIDropSessionImpl *)dropSession inIconListView:(id)arg3 {
    SBIconListView *listView = arg3;
    if ([draggedIcons count] > 0) {
        NSString *firstUID = GriddyIconID([draggedIcons firstObject]);
        GriddyIconLocationPreferences *draggedPrefs = firstUID ? locationPrefs[firstUID] : nil;
        if (draggedPrefs == nil && listView.model) {
            createNewLocationPrefs(listView.model, [draggedIcons firstObject], (NSUInteger)MAX((NSInteger)proposedIndex, 0));
            draggedPrefs = firstUID ? locationPrefs[firstUID] : nil;
        }
        if (!draggedPrefs) return %orig;

        touchPoint = [dropSession locationInView:listView];
        proposedIndex = calculateGridCellIndexForPoint(touchPoint, listView.iconLayoutRect, listView.gridSizeForCurrentOrientation, draggedPrefs.indexOffset, draggedPrefs.gridSize);

        if (proposedIndex == -1) {
            shouldGivePriority = NO;
            proposedIndex = draggedPrefs.ogIndex;
        } else {
            shouldGivePriority = YES;
        }
        for (SBIcon *ic in draggedIcons) {
            NSString *u = GriddyIconID(ic);
            if (u && locationPrefs[u]) locationPrefs[u].index = proposedIndex;
        }
    } else {
        touchPoint = [dropSession locationInView:listView];
        SBHIconGridSize offset = (SBHIconGridSize){0, 0};
        SBHIconGridSize size = (SBHIconGridSize){1, 1};
        proposedIndex = calculateGridCellIndexForPoint(touchPoint, listView.iconLayoutRect, listView.gridSizeForCurrentOrientation, offset, size);
    }
    return %orig;
}

%end


%hook SBHIconManager

- (BOOL)isEditing {
    BOOL og = isEditingLayout;
    isEditingLayout = %orig;

    if (og && !isEditingLayout) {
        NSMutableDictionary *tempDict = [[NSMutableDictionary alloc] init];
        for (NSString *key in locationPrefs) {
            GriddyIconLocationPreferences *p = locationPrefs[key];
            if (p) tempDict[key] = [NSNumber numberWithUnsignedLongLong:p.index];
        }
        [userDefaults setObject:tempDict forKey:((screenOrientation == 0 ? @"GriddyPortraitSave" : @"GriddyLandscapeSave"))];
    }
    return isEditingLayout;
}

- (void)addIcons:(NSArray <SBIcon *> *)arg1 intoFolderIcon:(SBFolderIcon *)folderIcon openFolderOnFinish:(BOOL)arg3 completion:(id)arg4 {
    @try {
        SBFolder *folder = folderIcon.folder;
        SBIconListModel *model = folder.firstList;
        proposedIndex = 0;

        for (SBIcon *icon in arg1) {
            if ([draggedIcons containsObject:icon]) {
                NSUInteger idx = findFirstOpenIndexInListStartingAt(model.icons, model.gridSize, proposedIndex);
                NSString *uid = GriddyIconID(icon);
                if (uid && locationPrefs[uid]) locationPrefs[uid].index = idx;
                proposedIndex = idx + 1;
            } else {
                NSString *uid = GriddyIconID(icon);
                if (uid && !locationPrefs[uid]) {
                    createNewLocationPrefs(model, icon, findFirstOpenIndexInListStartingAt(model.icons, model.gridSize, proposedIndex));
                }
            }
        }
        proposedIndex = -1;
    } @catch (__unused NSException *e) {}
    return %orig;
}

- (SBFolder *)createNewFolderFromRecipientIcon:(SBIcon *)recipientIcon grabbedIcon:(SBIcon *)grabbedIcon {
    NSString *rUID = GriddyIconID(recipientIcon);
    NSString *gUID = GriddyIconID(grabbedIcon);
    if (rUID && locationPrefs[rUID]) locationPrefs[rUID].index = 0;
    if (gUID && locationPrefs[gUID]) locationPrefs[gUID].index = 1;
    return %orig;
}

%end


%hook SBFolderIconImageView
- (CGRect)frameForMiniIconAtIndex:(NSUInteger)arg0 {
    SBFolder *folder = ((SBFolderIcon *)self.icon).folder;
    SBIconListModel *model = folder.firstList;
    if (!model.griddyShouldPatch) return %orig;
    if (!shouldPatchFolderIcon) return %orig;
    if ([model.icons count] > arg0) {
        SBIcon *icon = model.icons[arg0];
        NSString *uid = GriddyIconID(icon);
        GriddyIconLocationPreferences *prefs = uid ? locationPrefs[uid] : nil;
        if (prefs) return %orig(prefs.index);
    }
    return %orig;
}
%end

%hook _SBIconGridWrapperView

- (void)setImage:(UIImage *)image {
    if (!image) return %orig;

    _SBFolderPageElement *elem = self.element;
    SBIconGridImage *gridImageRef = (SBIconGridImage *)image;
    SBFolderIcon *folderIconRef = elem.folderIcon;
    if (elem == nil || gridImageRef == nil || folderIconRef == nil) return %orig;

    SBFolder *folder = folderIconRef.folder;
    SBIconListModel *firstPageModel = folder.firstList;
    if (firstPageModel == nil) return %orig;
    if (!firstPageModel.griddyShouldPatch) return %orig;

    if (!patchFoldersChecked) {
        shouldPatchFolderIcon = determineFolderPatching();
        patchFoldersChecked = YES;
    }
    if (!shouldPatchFolderIcon) return %orig;

    @try {
        SBIconView *iconView = self.folderIconImageView.iconView;
        SBFolderIconImageCache *imageCache = iconView.folderIconImageCache;
        SBIconListGridLayout *miniIconLayout = (SBIconListGridLayout *)gridImageRef.listLayout;

        NSString *folderKey = GriddyIconID(folderIconRef);
        if (!folderKey) return %orig;

        NSDictionary *cachedEntry = folderImageCache[folderKey];
        SBIconGridImage *griddyImage = cachedEntry[@"image"];
        NSString *cachedSignature = cachedEntry[@"signature"];
        NSString *currentSignature = GriddyFolderSignature(firstPageModel);
        BOOL signatureMatches = (cachedSignature != nil) && [cachedSignature isEqualToString:currentSignature];

        if (firstPageModel.griddyNeedsRefreshFolderImage || griddyImage == nil || !hasLoadedPrefs || !signatureMatches) {
            SBIconGridImage *tempImage = generateNewFolderImageForModel(firstPageModel, gridImageRef, imageCache, miniIconLayout);
            if (griddyImageSuccess == YES && tempImage != nil) {
                firstPageModel.griddyNeedsRefreshFolderImage = NO;
                folderImageCache[folderKey] = @{ @"image": tempImage, @"signature": currentSignature };
                griddyImage = tempImage;
            }
        }
        if (griddyImage == nil) return %orig;

        elem.gridImage = griddyImage;

        float neededWidth = (miniIconLayout.iconImageInfo).size.width * 0.75;
        float neededHeight = (miniIconLayout.iconImageInfo).size.height * 0.75;
        gridWrapperSize = CGRectMake((0.166666 * neededWidth), (0.166666 * neededHeight), neededWidth, neededHeight);
        return %orig(griddyImage);
    } @catch (__unused NSException *e) {
        return %orig;
    }
}

- (void)layoutSubviews {
    %orig;
    if (![self.folderIconImageView isKindOfClass:NSClassFromString(@"SBHLibraryAdditionalItemsIndicatorIconImageView")] && gridWrapperSize.size.width != 0 && shouldPatchFolderIcon) self.frame = gridWrapperSize;
}

%end

%hook SBIconListView
- (void)layoutIconsIfNeeded {
    if ([patchLocations containsObject:self.iconLocation])
        self.model.griddyShouldPatch = YES;
    else
        self.model.griddyShouldPatch = NO;

    if (!([self.iconLocation isEqualToString:@"SBIconLocationDock"] || [self.iconLocation isEqualToString:@"SBIconLocationFloatingDock"])) {
        return %orig;
    }

    if ((self.orientation == 1 || self.orientation == 2) && screenOrientation != 0) {
        screenOrientation = 0;
        portraitSavedDict = [userDefaults dictionaryForKey:@"GriddyPortraitSave"];
        if (portraitSavedDict){
            for (NSString *key in locationPrefs) {
                GriddyIconLocationPreferences *p = locationPrefs[key];
                if (p) p.index = (portraitSavedDict[key] == nil) ? 999 : ((NSNumber *)portraitSavedDict[key]).unsignedIntegerValue;
            }
        }
    } else if ((self.orientation == 3 || self.orientation == 4) && screenOrientation != 1) {
        screenOrientation = 1;
        landscapeSavedDict = [userDefaults dictionaryForKey:@"GriddyLandscapeSave"];
        if (landscapeSavedDict) {
            for (NSString *key in locationPrefs) {
                GriddyIconLocationPreferences *p = locationPrefs[key];
                if (p) p.index = (landscapeSavedDict[key] == nil) ? 999 : ((NSNumber *)landscapeSavedDict[key]).unsignedIntegerValue;
            }
        }
    }
    hasLoadedPrefs = YES;
    return %orig;
}
%end

%ctor {
    locationPrefs = [[NSMutableDictionary alloc] init];
    draggedIcons = [[NSMutableOrderedSet alloc] init];

    if ([[NSUserDefaults standardUserDefaults] dictionaryForKey:@"GriddyPortraitSave"] != nil
    || [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"GriddyLandscapeSave"] != nil) transferGriddySave();

    userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.mikifp.griddy"];
    portraitSavedDict = [userDefaults dictionaryForKey:@"GriddyPortraitSave"];
    landscapeSavedDict = [userDefaults dictionaryForKey:@"GriddyLandscapeSave"];

    NSString *temp[] = {@"SBIconLocationRoot", @"SBIconLocationFolder", @"SBIconLocationRootWithWidgets"};
    patchLocations = [NSArray arrayWithObjects:temp count:3];

    folderImageCache = [[NSMutableDictionary alloc] init];
}