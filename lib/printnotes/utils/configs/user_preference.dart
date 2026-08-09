import 'package:mix/printnotes/app.dart';

// TODO: Add button to reset all settings including config file
// Delete all set preferences
void clearAllPrefs() {
  App.localStorage.clear();
}

// For layout selection

class UserLayoutPref {
  // Left it as a string in case I want to add more layouts
  static void setLayoutView(String layoutView) {
    App.localStorage.setString('layoutView', layoutView);
  }

  static String getLayoutView() {
    return App.localStorage.getString('layoutView') ?? 'list';
  }

  // 用户是否手动切换过布局。用于区分「用户主动选的 grid」和
  // 「旧版默认值 grid」（后者应在启动时纠正为 list 单列）。
  static void setLayoutUserSet(bool userSet) {
    App.localStorage.setBool('layoutView_userSet', userSet);
  }

  static bool getLayoutUserSet() {
    return App.localStorage.getBool('layoutView_userSet') ?? false;
  }

  // Note preview length is for how many characters are displayed for each note
  // body on home screen before they get cut off
  static void setNotePreviewLength(int viewLength) {
    App.localStorage.setInt('notePreview', viewLength);
  }

  static int getNotePreviewLength() {
    return App.localStorage.getInt('notePreview') ?? 100;
  }
}

// For styling of app
// 主题统一由 MIX 的 ThemeController 驱动，这里只保留真正生效的代码高亮配置。

class UserThemingPref {
  static void setCodeHighlight(String highlight) {
    App.localStorage.setString('codeHighlight', highlight);
  }

  static String getCodeHighlight() {
    return App.localStorage.getString('codeHighlight') ?? '';
  }
}

class UserStylePref {
  static void setBgImagePath(String? path) {
    App.localStorage.setString('bgImgPath', path ?? '');
  }

  static String? getBgImagePath() {
    final path = App.localStorage.getString('bgImgPath');
    return path == '' ? null : path;
  }

  static void setBgImageOpacity(double opacity) {
    App.localStorage.setDouble('bgImgOpacity', opacity);
  }

  static double getBgImageOpacity() {
    return App.localStorage.getDouble('bgImgOpacity') ?? 0.5;
  }

  static void setBgImageFit(String fit) {
    App.localStorage.setString('bgImgFit', fit);
  }

  static String getBgImageFit() {
    return App.localStorage.getString('bgImgFit') ?? 'cover';
  }

  static void setBgImageRepeat(String repeat) {
    App.localStorage.setString('bgImgRepeat', repeat);
  }

  static String getBgImageRepeat() {
    return App.localStorage.getString('bgImgRepeat') ?? 'noRepeat';
  }

  static void setNoteTileOpacity(double opacity) {
    App.localStorage.setDouble('noteTileOpacity', opacity);
  }

  static double getNoteTileOpacity() {
    return App.localStorage.getDouble('noteTileOpacity') ?? 1;
  }

  static void setNoteTileShape(String shape) {
    App.localStorage.setString('noteTileShape', shape);
  }

  static String getNoteTileShape() {
    return App.localStorage.getString('noteTileShape') ?? 'round';
  }

  static void setNoteTilePadding(double padding) {
    App.localStorage.setDouble('noteTilePadding', padding);
  }

  static double getNoteTilePadding() {
    return App.localStorage.getDouble('noteTilePadding') ?? 10;
  }

  static void setNoteTileSpacing(double spacing) {
    App.localStorage.setDouble('noteTileSpacing', spacing);
  }

  static double getNoteTileSpacing() {
    // 默认 8：原默认 4 在手机 2 列下过于拥挤。
    return App.localStorage.getDouble('noteTileSpacing') ?? 8;
  }

  static void setNoteEditorPadding(double padding) {
    App.localStorage.setDouble('noteEditorPadding', padding);
  }

  static double getNoteEditorPadding() {
    return App.localStorage.getDouble('noteEditorPadding') ?? 8;
  }
}

// For saving what order items should be displayed in

class UserSortPref {
  static void setFolderPriority(String folderPriority) {
    App.localStorage.setString('folderPriority', folderPriority);
  }

  static String getFolderPriority() {
    return App.localStorage.getString('folderPriority') ?? 'none';
  }

  static void setSortOrder(String sortOrder) {
    App.localStorage.setString('sortOrder', sortOrder);
  }

  static String getSortOrder() {
    return App.localStorage.getString('sortOrder') ?? 'default';
  }
}

class UserAdvancedPref {
  // For hiding and showing title bar on desktop
  static void setTitleBarVisibility(bool visibility) {
    App.localStorage.setBool('titleBarVisibility', visibility);
  }

  static bool getTitleBarVisibility() {
    return App.localStorage.getBool('titleBarVisibility') ?? false;
  }

  // For keeping bottom navigation bar always visible on android 15+
  static void setBottomBarPersistence(bool visibility) {
    App.localStorage.setBool('bottomBarPersistence', visibility);
  }

  static bool getBottomBarPersistence() {
    return App.localStorage.getBool('bottomBarPersistence') ?? false;
  }

  // For having LaTeX rendered or not
  static void setLatexSupport(bool latexRendering) {
    App.localStorage.setBool('useLatex', latexRendering);
  }

  static bool getLatexSupport() {
    return App.localStorage.getBool('useLatex') ?? true;
  }

  // For using Frontmatter for metadata of not
  static void setFrontmatterSupport(bool useFM) {
    App.localStorage.setBool('useFrontmatter', useFM);
  }

  static bool getFrontmatterSupport() {
    return App.localStorage.getBool('useFrontmatter') ?? false;
  }
}

// For Editor settings

class UserEditorConfig {
  static void setFontSize(double fontSize) {
    App.localStorage.setDouble('editorConfigFontSize', fontSize);
  }

  static double getFontSize() {
    return App.localStorage.getDouble('editorConfigFontSize') ?? 16;
  }

  static setDefaultEditorMode(bool setMode) {
    App.localStorage.setBool('defaultEditorMode', setMode);
  }

  static bool getDefaultEditorMode() {
    return App.localStorage.getBool('defaultEditorMode') ?? false;
  }

  // static void setToolbarConfig(String config)  {
  //
  //   App.localStorage.setString('toolbar_config', config);
  // }

  // static String? getToolbarConfig()  {
  //
  //   return App.localStorage.getString('toolbar_config');
  // }
}
