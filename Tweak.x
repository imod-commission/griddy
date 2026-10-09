#import "Headers.h"
#import "Utils.h"
#import "GriddyIconLocationPreferences.h"
#import <objc/message.h>

// FIX (compile error): SBIcon's private selector `iconImageWithInfo:` is not declared
// in public headers, so the compiler complains. Declaring it in a local category both
// silences the error and lets us call it normally (no objc_msgSend gymnastics needed,
// which is important because the argument is a struct, not an object).
@interface SBIcon (GriddyPrivate)
- (UIImage *)iconImageWithInfo:(SBIconImageInfo)info;
@end

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
//three variables used to fix support for certain folder tweaks
CGRect gridWrapperSize;
BOOL shouldPatchFolderIcon = YES;
BOOL patchFoldersChecked = NO;
// FIX (bug 1): cache now stores a dict {image, signature} keyed by folder uniqueIdentifier
NSMutableDictionary<NSString *, NSDictionary *> *folderImageCache;
BOOL griddyImageSuccess = NO;
BOOL hasLoadedPrefs = NO;

// FIX (bug 1): signature now uses per-icon IMAGE FINGERPRINTS (CGImage pointers) instead of
// a global theme version. This makes the folder preview cache invalidate whenever the actual
// icon images change, regardless of who produced the change (system, theme tweak like 26Home,
// icon pack, etc). Works even if the theme tweak uses a private cache and never clears the
// standard system icon image caches.
static NSString *GriddyFolderSignature(SBIconListModel *model, SBIconListGridLayout *layout) {
    if (!model) return @"";
    NSMutableString *sig = [NSMutableString string];

    NSArray *icons = model.icons ?: @[];
    NSUInteger count = icons.count;
    [sig appendFormat:@"n%lu|", (unsigned long)count];

    NSUInteger previewCount = count < 9 ? count : 9;
    for (NSUInteger i = 0; i < previewCount; i++) {
        SBIcon *icon = icons[i];
        [sig appendFormat:@"%@|", icon.uniqueIdentifier ?: @"?"];

        // Pull the current rendered image for this icon and use its CGImage pointer as the
        // fingerprint. Any theme change that produces a new image will yield a different
        // CGImage, which changes the signature and forces a preview regeneration.
        UIImage *img = nil;
        if (layout && [icon respondsToSelector:@selector(iconImageWithInfo:)]) {
            @try {
                img = [icon iconImageWithInfo:layout.iconImageInfo];
            } @catch (__unused NSException *e) {
                img = nil;
            }
        }
        if (img) {
            CGImageRef cg = img.CGImage;
            if (cg) {
                [sig appendFormat:@"%p|", cg];
            } else {
                [sig appendFormat:@"%lu|", (unsigned long)img.hash];
            }
        } else {
            [sig appendFormat:@"nil|"];
        }
    }
    return sig;
}

%hook SBIconListModel
%property (assign, nonatomic) BOOL griddyShouldPatch;
%property (assign, nonatomic) BOOL griddyNeedsRefreshFolderImage;

//SBIconListGridCellInfo is essentially the template for laying out icons
//it matches up icon indexes(indexes of icons in the model's icon array)
//with grid cell indexes(indexes on the grid, starting with 0 at the top left)
- (SBIconListGridCellInfo *)gridCellInfoForGridSize:(SBHIconGridSize)arg1 options:(NSUInteger)arg2 {
    SBIconListGridCellInfo *info = %orig;

    //we don't want to modify every SBIconListModel, because they are used for things like
    //the today view, library view, or even the edit screen for widget stacks
    if (self.griddyShouldPatch) {
        self.icons = patchGridCellInfoForIconList(self.icons, info, self);
    }
    return info;
}

//addIcon can run on respring, but also later on when dragging icons between pages
- (BOOL)addIcon:(SBIcon *)icon options:(NSUInteger)arg1 {
    if ([self.parent isKindOfClass:NSClassFromString(@"SBHLibraryCategoryFolder")] || self.gridSize.rows > 32767) return %orig;

    //if an entry doesnt exist for the icon we are adding, import from save or create a new one
    //note: screenOrientation will be 0 if portrait, 1 if landscape, or -1 on respring
    //-1 on respring is caused by the fact that by default, orientation is set to 0-unknown directly after a respring
    //later, it becomes 1,2,3, or 4, where 1,2 are portrait and 3,4 are landscape
    if (!locationPrefs[icon.uniqueIdentifier]) {
        creatingNewIcon = YES;
        if (screenOrientation == 0 && portraitSavedDict) {
            if (portraitSavedDict[icon.uniqueIdentifier]) {
                createNewLocationPrefs(self, icon, portraitSavedDict[icon.uniqueIdentifier].unsignedIntegerValue);
            } else {
                createNewLocationPrefs(self, icon, ([draggedIcons containsObject:icon]) ? proposedIndex : [self.icons count]);
                locationPrefs[icon.uniqueIdentifier].priority = 1000;
            }
        } else if(screenOrientation == 1 && landscapeSavedDict) {
            if (landscapeSavedDict[icon.uniqueIdentifier]) {
                createNewLocationPrefs(self, icon, landscapeSavedDict[icon.uniqueIdentifier].unsignedIntegerValue);
            } else {
                createNewLocationPrefs(self, icon, ([draggedIcons containsObject:icon]) ? proposedIndex : [self.icons count]);
                locationPrefs[icon.uniqueIdentifier].priority = 1000;
            }
        } else {
            createNewLocationPrefs(self, icon, ([draggedIcons containsObject:icon]) ? proposedIndex : [self.icons count]);
            locationPrefs[icon.uniqueIdentifier].priority = 1000;
        }
    }
    
    //adding a placeholder can occur when dragging between pages
    if ([icon isKindOfClass:%c(SBPlaceholderIcon)]) {
        [draggedIcons addObject:icon];
        locationPrefs[icon.uniqueIdentifier].index = proposedIndex;
    }
    return %orig;
}

//replaceIcon is called on a couple different occasions, most notably when picking an icon up
//in this case, the icon to pick up will be replaced with an isntance of SBPlaceholderIcon
//however, if a placeholder already exists, it will just add it to the dragged placeholder
- (id)replaceIcon:(SBIcon *)oldIcon withIcon:(SBIcon *)newIcon options:(NSUInteger)arg2 {
    if (!self.griddyShouldPatch) return %orig;


    if (locationPrefs[oldIcon.uniqueIdentifier]) {
        GriddyIconLocationPreferences *newPrefs;

        //create a new entry in case it doesnt exist yet
        if (!locationPrefs[newIcon.uniqueIdentifier]) {
            newPrefs = [[GriddyIconLocationPreferences alloc] init];
        } else {
            newPrefs = locationPrefs[newIcon.uniqueIdentifier];
        }

        //this will run when dragging an icon from the app library out onto the home screen
        //in this case, we want to create a new entry, otherwise, swap all the info over to the new "real" icon
        if ([oldIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")] && ((SBPlaceholderIcon *)oldIcon).referencedIcon.uniqueIdentifier != newIcon.uniqueIdentifier) {
            createNewLocationPrefs(self, newIcon, proposedIndex);
        } else {
            GriddyIconLocationPreferences *oldPrefs = locationPrefs[oldIcon.uniqueIdentifier];
            newPrefs.index = oldPrefs.index;
            newPrefs.ogIndex = oldPrefs.ogIndex;
            newPrefs.gridSize = oldPrefs.gridSize;
            locationPrefs[newIcon.uniqueIdentifier] = newPrefs;
            if (![oldIcon isKindOfClass:NSClassFromString(@"SBWidgetIcon")]) [locationPrefs removeObjectForKey:oldIcon.uniqueIdentifier];
        }

        //get rid of the entry for the old placeholder icon
        if ([oldIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")]) {
            creatingNewIcon = NO;

            [locationPrefs removeObjectForKey:oldIcon.uniqueIdentifier];

            if ([draggedIcons containsObject:oldIcon]) [draggedIcons removeObject:oldIcon];
            if ([draggedIcons count] == 0) shouldRedrawList = YES;
        }

        //replace the real icon with the placeholder at the same index
        if ([newIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")]) newPrefs.index = proposedIndex;
    }

    //if replacing a placeholder with a placeholder (adding a new icon to the placeholder), swap them out
    if ([newIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")]) {
        if ([oldIcon isKindOfClass:NSClassFromString(@"SBPlaceholderIcon")] && [draggedIcons containsObject:oldIcon]) {
            [draggedIcons removeObject:oldIcon];
            [locationPrefs removeObjectForKey:oldIcon.uniqueIdentifier];
        }

        [draggedIcons addObject:newIcon];
    }
    return %orig;
}

//removing entry when removing icon
- (void)removeIcon:(SBIcon *)icon options:(NSUInteger)arg1 {
    %orig;
    //this if statement filters out removing icons in, for example, today view alterign the home screen
    //this is because widgets on the today view are the same object as the same widget on the home screen
    if (!self.griddyShouldPatch) return;
    if (isEditingLayout) [locationPrefs removeObjectForKey:icon.uniqueIdentifier];
}

%end


%hook SBIconView

//this runs when you pick up your first icon
- (void)dragInteraction:(id)arg1 sessionWillBegin:(id)arg2 {
    if (!self.icon) return %orig;
    //clear out dragged icons
    GriddyIconLocationPreferences *prefs = locationPrefs[self.icon.uniqueIdentifier];
    [draggedIcons removeAllObjects];

    %orig;
    //setup proposedIndex and add to draggedIcons
    proposedIndex = prefs.index;
    prefs.ogIndex = proposedIndex;
    if (![self isKindOfClass:NSClassFromString(@"SBHLibraryCategoryPodIconView")]) [draggedIcons addObject:self.icon];
}

//this runs any time an icon preview is generated for dragging
//ie, this runs for the first, second, third... icon you pick up 
- (id)dragInteraction:(id)arg1 previewForLiftingItem:(id)arg2 session:(_UIDropSessionImpl *)dropSession {
    if (!self.icon) return %orig;

    id ret = %orig;
    GriddyIconLocationPreferences *prefs = locationPrefs[self.icon.uniqueIdentifier];
    
    proposedIndex = prefs.index;
    prefs.ogIndex = proposedIndex;

    //we will always use the information from the first icon you pick up
    //this works because you can only pick up 1x1 icons in groups, and widgets can only be dragged 1 at a time
    if ([draggedIcons count] == 0) {
        //touch offset will be the location where you started grabbing the icon
        //it is the cgpoint in the SBIconView itself
        CGPoint touchOffset = [dropSession locationInView:self];

        //constrain touch offset, just in case
        if (touchOffset.x < 0) touchOffset.x = 0;
        if (touchOffset.y < 0) touchOffset.y = 0;
        if (touchOffset.x >= self.frame.size.width) touchOffset.x = self.frame.size.width-1;
        if (touchOffset.y >= self.frame.size.height) touchOffset.y = self.frame.size.height-1;
        
        //set index offset based on where in the icon you dragged
        unsigned short cols = (int)((touchOffset.x / self.frame.size.width) * prefs.gridSize.columns);
        unsigned short rows = (int)((touchOffset.y / self.frame.size.height) * prefs.gridSize.rows);
        [prefs setIndexOffsetColumns:cols rows:rows];

        //constrain indexOffset, just in case
        if (prefs.indexOffset.columns >= prefs.gridSize.columns) {[prefs setIndexOffsetColumns:0 rows:rows];}
        if (prefs.indexOffset.rows >= prefs.gridSize.rows) {[prefs setIndexOffsetColumns:cols rows:0];}
    }

    //add to dragged if not in the app library
    if (![self isKindOfClass:NSClassFromString(@"SBHLibraryCategoryPodIconView")]) {
        [draggedIcons insertObject:self.icon atIndex:0];
    }

    return ret;
}

//clean up dragged, just in case
- (void)dragInteraction:(id)arg1 session:(id)arg2 willEndWithOperation:(NSUInteger)arg3 {
    [draggedIcons removeAllObjects];
    proposedIndex = -1;
    return %orig;
}

%end


%hook SBIconController

//this will run anytime you pause your drag
- (BOOL)iconManager:(id)arg1 canAcceptDropInSession:(_UIDropSessionImpl *)dropSession inIconListView:(id)arg3 {
    SBIconListView *listView = arg3;
    //if we are dragging something, we want to deal with the logic for getting the grid cell index at that point
    if ([draggedIcons count] > 0) {
        //use the first object for data abput hat e are dragging
        GriddyIconLocationPreferences *draggedPrefs = locationPrefs[[draggedIcons firstObject].uniqueIdentifier];
        if (draggedPrefs == nil) {
            createNewLocationPrefs(listView.model, [draggedIcons firstObject], proposedIndex);
            draggedPrefs = locationPrefs[[draggedIcons firstObject].uniqueIdentifier];
        }

        //get the grid cell index for wherever we are touching
        touchPoint = [dropSession locationInView:listView];
        proposedIndex = calculateGridCellIndexForPoint(touchPoint, listView.iconLayoutRect, listView.gridSizeForCurrentOrientation, draggedPrefs.indexOffset, draggedPrefs.gridSize);
        
        //this will run only if we are out of bounds of the SBIconListView
        //in this case, we want to make sure the icon does not move anyhting else when we let go
        if (proposedIndex == -1) {
            shouldGivePriority = NO;
            proposedIndex = draggedPrefs.ogIndex;
        } else {
            shouldGivePriority = YES;
        }
        //set the proposed index for each icon we are dragging
        for(int i = 0; i < [draggedIcons count]; i++) {
            locationPrefs[draggedIcons[i].uniqueIdentifier].index = proposedIndex;
        }
    } else {
        //this runs for icons dragged from the app library
        //we cannot add app library icons to dragged because they are 
        //the same instance as the corresponding icon on the home screen
        //adding this to dragged would mess up the icon already on the home screen, so we do it in a roundabout way
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

    //if we are ending an edit, we want to save our layout
    if (og && !isEditingLayout) {
        NSMutableDictionary *tempDict = [[NSMutableDictionary alloc] init];
        for (NSString *key in locationPrefs) {
            tempDict[key] = [NSNumber numberWithUnsignedLongLong:locationPrefs[key].index];
        }

        [userDefaults setObject:tempDict forKey:((screenOrientation == 0 ? @"GriddyPortraitSave" : @"GriddyLandscapeSave"))];
    }

    return isEditingLayout;
}

//this function is called when adding icons to a folder icon that exists on the homescreen
//note: this is only run when you let go over the folder preview, not if you actually open the folder up
- (void)addIcons:(NSArray <SBIcon *> *)arg1 intoFolderIcon:(SBFolderIcon *)folderIcon openFolderOnFinish:(BOOL)arg3 completion:(id)arg4 {
    
    SBFolder *folder = folderIcon.folder;
    SBIconListModel *model = folder.firstList;

    proposedIndex = 0;

    //find open spots for each icon
    for (int i = 0; i < [arg1 count]; i++) {
        SBIcon *icon = arg1[i];
        if ([draggedIcons containsObject:arg1[i]]) {
            NSUInteger idx = findFirstOpenIndexInListStartingAt(model.icons, model.gridSize, proposedIndex);
            GriddyIconLocationPreferences *prefs = locationPrefs[icon.uniqueIdentifier];
            prefs.index = idx;
            proposedIndex = idx + 1;
        } else {
            //if its not in dragged(app library drag) make a new entry
            if (!locationPrefs[icon.uniqueIdentifier]) {
                createNewLocationPrefs(model, icon, findFirstOpenIndexInListStartingAt(model.icons, model.gridSize, proposedIndex));
            }
        }
    }

    proposedIndex = -1;
    return %orig;
}

//this runs when creating a new folder
- (SBFolder *)createNewFolderFromRecipientIcon:(SBIcon *)recipientIcon grabbedIcon:(SBIcon *)grabbedIcon {
    GriddyIconLocationPreferences *prefs = locationPrefs[recipientIcon.uniqueIdentifier];
    
    if (prefs) prefs.index = 0;
    prefs = locationPrefs[grabbedIcon.uniqueIdentifier];
    if (prefs) prefs.index = 1;

    return %orig;
}

%end


%hook SBFolderIconImageView
//this patches the animation for opening and closing a folder(the zoom in and out)
- (CGRect)frameForMiniIconAtIndex:(NSUInteger)arg0 {
    SBFolder *folder = ((SBFolderIcon *)self.icon).folder;
    SBIconListModel *model = folder.firstList;

    if (!model.griddyShouldPatch) return %orig;
    if (!shouldPatchFolderIcon) return %orig;

    if ([model.icons count] > arg0) {
        SBIcon *icon = model.icons[arg0];
        GriddyIconLocationPreferences *prefs = locationPrefs[icon.uniqueIdentifier];
        return %orig(prefs.index);
    }

    return %orig;
}

%end

//_SBIconGridWrapperView is the image view for the mini icons on the folder icon
%hook _SBIconGridWrapperView

- (void)setImage:(UIImage *)image {
    if (!image) return %orig;
    
    //getting needed items
    _SBFolderPageElement *elem = self.element;
    SBIconGridImage *gridImageRef = (SBIconGridImage *)image;
    SBFolderIcon *folderIconRef = elem.folderIcon;

    if (elem == nil || gridImageRef == nil || folderIconRef == nil) return %orig;

    // FIX (bug 2): Always use the FIRST page of the folder, not the page the user is
    // currently viewing. Using elem.pageIndex caused previews to render the page the
    // user was on when they moved an icon (e.g. page 2/3), instead of page 1.
    SBFolder *folder = folderIconRef.folder;
    SBIconListModel *firstPageModel = folder.firstList;
    if (firstPageModel == nil) return %orig;

    if (!firstPageModel.griddyShouldPatch) return %orig;

    // checks a bunch of folder tweaks to determine if it should patch the image
    if (!patchFoldersChecked) {
        shouldPatchFolderIcon = determineFolderPatching();
        patchFoldersChecked = YES;
    }

    if (!shouldPatchFolderIcon) return %orig;

    // version 1.0.4 moves a lot of this code to it's own function
    // this is because we now create iamges only if we need to, and cache them for use later
    // this code was crashing on 1.0.3 and lower, and I believe it is because we were generating too many images
    SBIconView *iconView = self.folderIconImageView.iconView;
    SBFolderIconImageCache *imageCache = iconView.folderIconImageCache;

    SBIconListGridLayout *miniIconLayout = (SBIconListGridLayout *)gridImageRef.listLayout;

    // FIX (bug 1): cache entry now stores {image, signature}. The signature is built from
    // the first-page icon identifiers AND each icon's current rendered image fingerprint
    // (CGImage pointer). Any theme change that produces new icon images will change the
    // fingerprint, so the preview regenerates on next read without depending on any
    // system notification or a global theme version counter.
    NSDictionary *cachedEntry = folderImageCache[folderIconRef.uniqueIdentifier];
    SBIconGridImage *griddyImage = cachedEntry[@"image"];
    NSString *cachedSignature = cachedEntry[@"signature"];
    NSString *currentSignature = GriddyFolderSignature(firstPageModel, miniIconLayout);
    BOOL signatureMatches = (cachedSignature != nil) && [cachedSignature isEqualToString:currentSignature];

    //get image from cache or generate new one
    if (firstPageModel.griddyNeedsRefreshFolderImage || griddyImage == nil || !hasLoadedPrefs || !signatureMatches) {
        SBIconGridImage *tempImage = generateNewFolderImageForModel(firstPageModel, gridImageRef, imageCache, miniIconLayout);
        if (griddyImageSuccess == YES && tempImage != nil) {
            firstPageModel.griddyNeedsRefreshFolderImage = NO;
            folderImageCache[folderIconRef.uniqueIdentifier] = @{
                @"image": tempImage,
                @"signature": currentSignature
            };
            griddyImage = tempImage;
        }
    }

    if (griddyImage == nil) return %orig;

    elem.gridImage = griddyImage;

    float neededWidth = (miniIconLayout.iconImageInfo).size.width * 0.75;
    float neededHeight = (miniIconLayout.iconImageInfo).size.height * 0.75;

    gridWrapperSize = CGRectMake( (0.166666 * neededWidth), (0.166666 * neededHeight), neededWidth, neededHeight);
    return %orig(griddyImage);
}

- (void)layoutSubviews {
    %orig;
    //this if statement is a bit sketchy, and I will try to clean it up in a future version
    if (![self.folderIconImageView isKindOfClass:NSClassFromString(@"SBHLibraryAdditionalItemsIndicatorIconImageView")] && gridWrapperSize.size.width != 0 && shouldPatchFolderIcon) self.frame = gridWrapperSize;
}


%end

%hook SBIconListView
- (void)layoutIconsIfNeeded {

    //determine if the model should be patched or not
    if ([patchLocations containsObject:self.iconLocation])
        self.model.griddyShouldPatch = YES;
    else
        self.model.griddyShouldPatch = NO;

    // FIX (bug 3): We still observe the dock purely for orientation detection.
    // The dock itself is no longer in patchLocations, so griddyShouldPatch stays NO for it.
    //we will only use the dock for deciding rotation
    //SBIconLocationFloatingDockSuggestions is for floating dock
    if (!([self.iconLocation isEqualToString:@"SBIconLocationDock"] || [self.iconLocation isEqualToString:@"SBIconLocationFloatingDock"])) {
        return %orig;
    }

    //load corresponding saved state
    if ((self.orientation == 1 || self.orientation == 2) && screenOrientation != 0) {
        screenOrientation = 0;
        portraitSavedDict = [userDefaults dictionaryForKey:@"GriddyPortraitSave"];

        if (portraitSavedDict){
            for (NSString *key in locationPrefs) {
                ((GriddyIconLocationPreferences *)locationPrefs[key]).index = (portraitSavedDict[key] == nil) ? 999 : ((NSNumber *)portraitSavedDict[key]).unsignedIntegerValue;
            }
        }
    } else if ((self.orientation == 3 || self.orientation == 4) && screenOrientation != 1) {
        screenOrientation = 1;
        landscapeSavedDict = [userDefaults dictionaryForKey:@"GriddyLandscapeSave"];

        if (landscapeSavedDict) {
            for (NSString *key in locationPrefs) {
                ((GriddyIconLocationPreferences *)locationPrefs[key]).index = (landscapeSavedDict[key] == nil) ? 999 : ((NSNumber *)landscapeSavedDict[key]).unsignedIntegerValue;
            }
        }
    }
    hasLoadedPrefs = YES;
    return %orig;
}
%end

//setup variables and load saves
%ctor {
    locationPrefs = [[NSMutableDictionary alloc] init]; 
    draggedIcons = [[NSMutableOrderedSet alloc] init];  

    // transfer save to new location
    if ([[NSUserDefaults standardUserDefaults] dictionaryForKey:@"GriddyPortraitSave"] != nil 
    || [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"GriddyLandscapeSave"] != nil) transferGriddySave();

    // new location to save data :D
    // thank you to Ichitaso for this: https://github.com/ichitaso
    userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.mikifp.griddy"];

    portraitSavedDict = [userDefaults dictionaryForKey:@"GriddyPortraitSave"];
    landscapeSavedDict = [userDefaults dictionaryForKey:@"GriddyLandscapeSave"];

    // FIX (bug 3): Removed SBIconLocationDock and SBIconLocationFloatingDock.
    // The dock has its own fixed layout that doesn't need Griddy's grid patching,
    // and patching it caused conflicts. Dock is still observed in layoutIconsIfNeeded
    // for orientation detection only.
    NSString *temp[] = {@"SBIconLocationRoot", @"SBIconLocationFolder", @"SBIconLocationRootWithWidgets"};
    patchLocations = [NSArray arrayWithObjects:temp count:3];

    folderImageCache = [[NSMutableDictionary alloc] init];
}