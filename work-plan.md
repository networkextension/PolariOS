# polarstart UX 重构工作计划

> 基于 `imp.md` + `imp2.md`（路线 B：长内容社区）落地。
> 原则：用户不应看到 markdown 路径 / section 加载错误 / AI 联系人污染；每页仅 1 个主 CTA。

## 一、信息架构（最终版）

```
底部导航（4个）
├─ 🏠 首页（Feed）       PostsListViewController
├─ ➕ 创作（弹层）        + → ActionSheet[发动态 | 写文章]
├─ 💬 消息               MessagesHubViewController
│    ├─ 聊天（AI助手置顶 + 私聊）
│    └─ 通知（system）
└─ 👤 我的               UserProfileViewController
     └─ Tab[动态 | 文章 | 收藏]
```

关键删除：
- ❌ Notes tab（已删）
- ❌ CreateHubViewController（二级中转页，换成弹层）
- ❌ Profile Reviews / 可见 ID
- ❌ AI 伪装成联系人（GPT5/美股分析员/灵魂导师）

## 二、代码现状速览（2026-04-17）

已完成：
- ✅ MainTabBarController 4-tab（帖子/创作/消息/我的）
- ✅ Feed 右上角「创建」已弹 ActionSheet（`feed.create.sheet.*`）
- ✅ 消息分段：聊天 | 通知（`MessagesHubViewController` + `NotificationsListViewController`）
- ✅ 通知路由（post / markdown / chat list / none）
- ✅ 通知未读 badge
- ✅ markdown.polish / companion AI 辅助字符串全齐

需改造：
- ✅ 创作 tab 改为 + 弹层（MainTabBarController.shouldSelect 拦截中间 tab）
- ✅ CreatePostViewController 移除 postType 文案，Section 下沉为 chip
- ✅ MarkdownList：title 改为「我的文章」，file_path 已隐藏
- ✅ 新建会话 action sheet 去掉 Bot 选项，Bot 入口只保留在聊天列表顶部 AI 助手置顶行
- ✅ Feed 文章卡：metaText 显示「📄 文章 · 日期」，subtitle 提示「点击阅读全文」
- ✅ MarkdownDetail 沉浸阅读：去掉 monospaced 字体，放大字号/行距，加大标题 + 发布时间头部
- ✅ Profile Reviews 区块已删除
- ✅ 独立 AIAssistantViewController：AI 助手行无会话时推入 Bot 中枢（系统 + 自定义 Bot 分组列表）
- ✅ AppStyle tokens 已抽出（Color/Spacing/Radius/Font），MarkdownDetail 头部率先接入
- ⏳ Feed 文章卡封面/摘要（目前后端模型无 cover/summary 字段）

## 三、任务分 P（执行顺序）

### P0（必做，本周完成）

1. **P0-1 精简底部导航** — ✅ 已完成（沿用）
2. **P0-2 创作入口改弹层**
   - MainTabBarController 中间 tab 用占位 VC；`shouldSelect` 拦截后 `present` ActionSheet[发动态 | 写文章]
   - 删除 `CreateHubViewController` 及 `create.hub.*` 字符串
3. **P0-3 发动态极简流**
   - CreatePostViewController 单页：大输入框 + 图片/视频/AI icon + 蓝色「发布」
   - Section 选择从主流程下沉到输入下方 chip；加载失败静默
   - 隐藏 markdown 切换；切换「写文章」由上层决定
4. **P0-4 写文章（长内容）**
   - MarkdownListViewController 改名/重构为「文章管理」；入口只在 Profile 和弹层「写文章」
   - MarkdownCreateViewController / Detail 去 markdown 路径展示；标题 + 正文 + AI 辅助 + 发布
5. **P0-5 消息拆分** — ✅ 已完成（沿用）
6. **P0-6 AI 助手聚合入口**
   - 新增 `AIAssistantViewController`（或复用 bot 话题 VC），聊天列表顶部置顶单入口
   - Bot 列表从私聊起始页下线，改为 AI 助手内部切换

### P1（下周）

7. **P1-1 Feed 双卡片**：`UserContentCell` 分动态卡 / 文章卡（封面 + 标题加粗 + 2 行摘要 + 作者·阅读量）
8. **P1-2 文章沉浸阅读页**：新建 `ArticleReaderViewController`（字号 16–18、宽松行距、图片全宽、长文目录）
9. **P1-3 Profile 重做**：头像+名+简介 / 3 数字 / Tab[动态|文章|收藏]，删 Reviews
10. **P1-4 空状态补齐**：AI 助手 / 收藏 / 文章管理 / 推荐-关注切换空流
11. **P1-5 视觉规范**：主色=品牌蓝仅主 CTA、背景 #F5F5F5、卡片白、文字 #111/#666、字号 17-20/15/13

### P2（后端阻塞）

12. **P2-1 互动与增长**：点赞/评论/收藏/关注的乐观更新；推荐 vs 关注；AI 参与评论/选题
    - 点赞/评论：已实现
    - 帖子收藏：后端无 `/api/posts/:id/bookmark`，按钮已移除，等后端提供
    - 关注：后端无 follow/unfollow/followers，推荐 vs 关注 Feed 拆分暂无法实现
    - AI 参与评论/选题：后端无接口，暂无法实现

## 四、涉及文件映射

| 任务 | 文件 |
|---|---|
| P0-2 | `MainTabBarController.swift`, 删 `ListPlaceholdersViewController.swift` 中 CreateHub 段 |
| P0-3 | `CreatePostViewController.swift`, `PostService.swift`, `TagService.swift` |
| P0-4 | `MarkdownListViewController.swift`, `MarkdownService.swift` |
| P0-6 | 新建 `AIAssistantViewController.swift`, `PrivateMessagesViewController.swift` |
| P1-1 | `PostsListViewController.swift`, `UserContentCell.swift` |
| P1-2 | 新建 `ArticleReaderViewController.swift`（替换 `MarkdownDetailViewController` 在 Feed 路径上的使用） |
| P1-3 | `UserProfileViewController.swift`, `UserProfileModels.swift` |
| P1-4 | `EmptyStateView.swift` |
| P1-5 | `Assets.xcassets`, 全局样式常量（新建 `AppStyle.swift`） |

## 五、完成标准

- ✅ 用户看不到 `file_path`、「section 加载失败」、markdown 源码
- ✅ AI 只有 1 个入口，内部多 agent；消息列表不出现 bot 单项
- ✅ 一页最多 1 个蓝色 CTA（CreatePost/Profile 的次要按钮已降级为 gray）
- ⚠️ 用户 3 秒内可发一条动态（主流程已最短化：大输入框 + 发布；图片/视频/分区已降为次级）
