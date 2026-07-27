#import "DYYYKeywordListView.h"
#import "DYYYCustomInputView.h"
#import "DYYYUtils.h"

@interface DYYYKeywordListView () <UIGestureRecognizerDelegate>

@property(nonatomic, strong) UIVisualEffectView *blurView;
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UITableView *keywordsTableView;
@property(nonatomic, strong) UIButton *addButton;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, strong) UIButton *confirmButton;
@property(nonatomic, assign) CGRect originalFrame;
@property(nonatomic, strong) NSMutableArray *keywords;

@end

@implementation DYYYKeywordListView

- (void)setAddItemTitle:(NSString *)addItemTitle {
    _addItemTitle = [addItemTitle copy];
    NSString *addTitle = _addItemTitle ?: @"添加";
    if (self.addButton) {
        [self.addButton setTitle:[@"+ " stringByAppendingString:addTitle] forState:UIControlStateNormal];
    }
}

- (instancetype)initWithTitle:(NSString *)title keywords:(NSArray *)keywords {
    if (self = [super initWithFrame:UIScreen.mainScreen.bounds]) {
        self.keywords = [NSMutableArray arrayWithArray:keywords ?: @[]];
        self.addItemTitle = @"添加过滤项";
        self.editItemTitle = @"编辑过滤项";
        self.inputPlaceholder = @"请输入过滤项";
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];

        BOOL isDarkMode = [DYYYUtils isDarkMode];

        // 创建模糊效果背景
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:isDarkMode ? UIBlurEffectStyleDark : UIBlurEffectStyleLight]];
        self.blurView.frame = self.bounds;
        self.blurView.alpha = isDarkMode ? 0.3 : 0.2;
        [self addSubview:self.blurView];

        // 创建内容视图 - 为底部操作区预留完整空间，并兼容较矮屏幕
        CGFloat screenHeight = CGRectGetHeight(self.bounds);
        CGFloat contentHeight = MIN(430.0, MAX(320.0, screenHeight - 80.0));
        self.contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, contentHeight)];
        self.contentView.center = CGPointMake(self.frame.size.width / 2, screenHeight / 3);
        self.originalFrame = self.contentView.frame;
        self.contentView.backgroundColor = isDarkMode ? [UIColor colorWithRed:30 / 255.0 green:30 / 255.0 blue:30 / 255.0 alpha:1.0] : [UIColor whiteColor];
        self.contentView.layer.cornerRadius = 12;
        self.contentView.layer.masksToBounds = YES;
        [self addSubview:self.contentView];

        // 主标题 - 根据模式设置文本颜色
        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, 260, 24)];
        self.titleLabel.text = title ?: @"过滤过滤项";
        self.titleLabel.textColor =
            isDarkMode ? [UIColor colorWithRed:230 / 255.0 green:230 / 255.0 blue:235 / 255.0 alpha:1.0] : [UIColor colorWithRed:45 / 255.0 green:47 / 255.0 blue:56 / 255.0 alpha:1.0];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
        [self.contentView addSubview:self.titleLabel];

        CGFloat buttonContainerHeight = 55.5;
        CGFloat buttonSeparatorY = contentHeight - buttonContainerHeight - 0.5;
        CGFloat addButtonY = buttonSeparatorY - 50.0;
        CGFloat tableHeight = MAX(100.0, addButtonY - 64.0);

        // 表格视图 - 根据模式设置背景色和分隔线颜色
        self.keywordsTableView = [[UITableView alloc] initWithFrame:CGRectMake(20, 54, 260, tableHeight)];
        self.keywordsTableView.delegate = self;
        self.keywordsTableView.dataSource = self;
        self.keywordsTableView.backgroundColor =
            isDarkMode ? [UIColor colorWithRed:45 / 255.0 green:45 / 255.0 blue:45 / 255.0 alpha:1.0] : [UIColor colorWithRed:245 / 255.0 green:245 / 255.0 blue:245 / 255.0 alpha:1.0];
        self.keywordsTableView.layer.cornerRadius = 8;
        self.keywordsTableView.tableFooterView = [UIView new];  // 隐藏空行分隔线
        self.keywordsTableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        self.keywordsTableView.separatorInset = UIEdgeInsetsMake(0, 15, 0, 15);
        self.keywordsTableView.separatorColor =
            isDarkMode ? [UIColor colorWithRed:60 / 255.0 green:60 / 255.0 blue:60 / 255.0 alpha:1.0] : [UIColor colorWithRed:230 / 255.0 green:230 / 255.0 blue:230 / 255.0 alpha:1.0];
        [self.contentView addSubview:self.keywordsTableView];

        // 添加按钮 - 根据模式设置背景色
        self.addButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.addButton.frame = CGRectMake(20, addButtonY, 260, 40);
        self.addButton.backgroundColor =
            isDarkMode ? [UIColor colorWithRed:45 / 255.0 green:45 / 255.0 blue:45 / 255.0 alpha:1.0] : [UIColor colorWithRed:245 / 255.0 green:245 / 255.0 blue:245 / 255.0 alpha:1.0];
        self.addButton.layer.cornerRadius = 8;
        NSString *addTitle = self.addItemTitle ?: @"添加";
        [self.addButton setTitle:[@"+ " stringByAppendingString:addTitle] forState:UIControlStateNormal];
        [self.addButton setTitleColor:[UIColor colorWithRed:11 / 255.0 green:223 / 255.0 blue:154 / 255.0 alpha:1.0] forState:UIControlStateNormal];  // 强调色保持不变 #0BDF9A
        [self.addButton addTarget:self action:@selector(addKeywordTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:self.addButton];

        // 添加内容和按钮之间的分割线 - 根据模式设置颜色
        UIView *contentButtonSeparator = [[UIView alloc] initWithFrame:CGRectMake(0, buttonSeparatorY, 300, 0.5)];
        contentButtonSeparator.backgroundColor =
            isDarkMode ? [UIColor colorWithRed:60 / 255.0 green:60 / 255.0 blue:60 / 255.0 alpha:1.0] : [UIColor colorWithRed:230 / 255.0 green:230 / 255.0 blue:230 / 255.0 alpha:1.0];
        [self.contentView addSubview:contentButtonSeparator];

        // 按钮容器
        UIView *buttonContainer = [[UIView alloc] initWithFrame:CGRectMake(0, contentButtonSeparator.frame.origin.y + 0.5, 300, buttonContainerHeight)];
        [self.contentView addSubview:buttonContainer];

        // 取消按钮 - 根据模式设置文本颜色
        self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.cancelButton.frame = CGRectMake(0, 0, 149.5, 55.5);
        self.cancelButton.backgroundColor = [UIColor clearColor];
        [self.cancelButton setTitle:@"取消" forState:UIControlStateNormal];
        [self.cancelButton
            setTitleColor:isDarkMode ? [UIColor colorWithRed:160 / 255.0 green:160 / 255.0 blue:165 / 255.0 alpha:1.0] : [UIColor colorWithRed:124 / 255.0 green:124 / 255.0 blue:130 / 255.0 alpha:1.0]
                 forState:UIControlStateNormal];
        [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [buttonContainer addSubview:self.cancelButton];

        // 按钮之间的分割线 - 根据模式设置颜色
        UIView *buttonSeparator = [[UIView alloc] initWithFrame:CGRectMake(149.5, 0, 0.5, 55.5)];
        buttonSeparator.backgroundColor =
            isDarkMode ? [UIColor colorWithRed:60 / 255.0 green:60 / 255.0 blue:60 / 255.0 alpha:1.0] : [UIColor colorWithRed:230 / 255.0 green:230 / 255.0 blue:230 / 255.0 alpha:1.0];
        [buttonContainer addSubview:buttonSeparator];

        // 确认按钮 - 根据模式设置文本颜色
        self.confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.confirmButton.frame = CGRectMake(150, 0, 150, 55.5);
        self.confirmButton.backgroundColor = [UIColor clearColor];
        [self.confirmButton setTitle:@"确定" forState:UIControlStateNormal];
        [self.confirmButton
            setTitleColor:isDarkMode ? [UIColor colorWithRed:230 / 255.0 green:230 / 255.0 blue:235 / 255.0 alpha:1.0] : [UIColor colorWithRed:45 / 255.0 green:47 / 255.0 blue:56 / 255.0 alpha:1.0]
                 forState:UIControlStateNormal];
        [self.confirmButton addTarget:self action:@selector(confirmTapped) forControlEvents:UIControlEventTouchUpInside];
        [buttonContainer addSubview:self.confirmButton];

        self.contentView.center = CGPointMake(self.frame.size.width / 2, screenHeight / 2);
        self.originalFrame = self.contentView.frame;

        UITapGestureRecognizer *backgroundTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped:)];
        backgroundTap.delegate = self;
        backgroundTap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:backgroundTap];
        self.accessibilityViewIsModal = YES;

        [DYYYUtils prepareModalOverlayView:self contentView:self.contentView];
    }
    return self;
}

- (void)show {
    UIWindow *window = [DYYYUtils getActiveWindow];
    if (!window) {
        window = UIApplication.sharedApplication.windows.firstObject;
    }
    if (!window) {
        return;
    }
    [window addSubview:self];

    [DYYYUtils animateModalOverlayViewIn:self contentView:self.contentView completion:nil];
}

- (void)dismiss {
    [self dismissWithCompletion:nil];
}

- (void)dismissWithCompletion:(void (^)(void))completion {
    [DYYYUtils animateModalOverlayViewOut:self
                             contentView:self.contentView
                              completion:^(__unused BOOL finished) {
                                [self removeFromSuperview];
                                if (completion) {
                                    completion();
                                }
                              }];
}

- (void)addKeywordTapped {
    DYYYCustomInputView *inputView = [[DYYYCustomInputView alloc] initWithTitle:self.addItemTitle defaultText:nil placeholder:self.inputPlaceholder];

    __weak __typeof(self) weakSelf = self;
    inputView.onConfirm = ^(NSString *text) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf || text.length == 0) {
          return;
      }

      NSMutableArray<NSString *> *itemsToAdd = [NSMutableArray array];
      for (NSString *keyword in [text componentsSeparatedByString:@","]) {
          NSString *trimmedKeyword = [keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
          if (trimmedKeyword.length > 0) {
              [itemsToAdd addObject:trimmedKeyword];
          }
      }
      if (itemsToAdd.count == 0) {
          return;
      }

      NSUInteger firstIndex = strongSelf.keywords.count;
      [strongSelf.keywords addObjectsFromArray:itemsToAdd];
      NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray arrayWithCapacity:itemsToAdd.count];
      for (NSUInteger index = 0; index < itemsToAdd.count; index++) {
          [indexPaths addObject:[NSIndexPath indexPathForRow:(NSInteger)(firstIndex + index) inSection:0]];
      }
      [strongSelf.keywordsTableView insertRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationAutomatic];
    };

    [inputView show];
}

- (void)confirmTapped {
    NSArray *keywords = [self.keywords copy];
    void (^confirmAction)(NSArray *) = [self.onConfirm copy];
    [self dismissWithCompletion:^{
      if (confirmAction) {
          confirmAction(keywords);
      }
    }];
}

- (void)cancelTapped {
    void (^cancelAction)(void) = [self.onCancel copy];
    [self dismissWithCompletion:^{
      if (cancelAction) {
          cancelAction();
      }
    }];
}

- (void)backgroundTapped:(UITapGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        [self cancelTapped];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isDescendantOfView:self.contentView];
}

- (BOOL)accessibilityPerformEscape {
    [self cancelTapped];
    return YES;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.keywords.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"KeywordCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];

    BOOL isDarkMode = [DYYYUtils isDarkMode];

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier];

        // 删除按钮
        UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeCustom];
        deleteButton.frame = CGRectMake(0, 0, 30, 30);

        // 自绘制叉号图标
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(12, 12), NO, 0);
        CGContextRef context = UIGraphicsGetCurrentContext();

        CGContextSetStrokeColorWithColor(context, [UIColor colorWithRed:180 / 255.0 green:180 / 255.0 blue:185 / 255.0 alpha:1.0].CGColor);
        CGContextSetLineWidth(context, 1.5);

        CGContextMoveToPoint(context, 1, 1);
        CGContextAddLineToPoint(context, 11, 11);

        CGContextMoveToPoint(context, 11, 1);
        CGContextAddLineToPoint(context, 1, 11);

        CGContextStrokePath(context);

        UIImage *xImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        [deleteButton setImage:xImage forState:UIControlStateNormal];
        deleteButton.adjustsImageWhenHighlighted = YES;

        [deleteButton addTarget:self action:@selector(deleteKeyword:) forControlEvents:UIControlEventTouchUpInside];

        cell.accessoryView = deleteButton;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor =
            isDarkMode ? [UIColor colorWithRed:230 / 255.0 green:230 / 255.0 blue:235 / 255.0 alpha:1.0] : [UIColor colorWithRed:45 / 255.0 green:47 / 255.0 blue:56 / 255.0 alpha:1.0];
    }

    // 配置单元格
    cell.textLabel.text = self.keywords[indexPath.row];
    cell.accessoryView.tag = indexPath.row;

    // 设置背景色透明，以便表格背景色可见
    cell.backgroundColor = [UIColor clearColor];

    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 44.0;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *currentKeyword = self.keywords[indexPath.row];
    DYYYCustomInputView *inputView = [[DYYYCustomInputView alloc] initWithTitle:self.editItemTitle defaultText:currentKeyword placeholder:self.inputPlaceholder];

    __weak __typeof(self) weakSelf = self;
    inputView.onConfirm = ^(NSString *text) {
      if (text.length > 0) {
          weakSelf.keywords[indexPath.row] = text;
          [weakSelf.keywordsTableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationAutomatic];
      }
    };

    [inputView show];
}

- (void)deleteKeyword:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < self.keywords.count) {
        [self.keywords removeObjectAtIndex:index];
        [self.keywordsTableView deleteRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:index inSection:0] ] withRowAnimation:UITableViewRowAnimationAutomatic];
        dispatch_async(dispatch_get_main_queue(), ^{
          for (NSIndexPath *indexPath in self.keywordsTableView.indexPathsForVisibleRows) {
              UITableViewCell *cell = [self.keywordsTableView cellForRowAtIndexPath:indexPath];
              cell.accessoryView.tag = indexPath.row;
          }
        });
    }
}

@end
