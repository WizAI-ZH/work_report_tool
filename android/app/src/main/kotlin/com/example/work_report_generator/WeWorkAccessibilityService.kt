package com.example.work_report_generator

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * 企业微信自动发送无障碍服务（手机端）。
 *
 * 基于 uiautomator dump 真实控件树实现，适配企微手机版实际布局：
 * - 界面语言可能是繁体中文（訊息/搜尋/發送/檔案傳輸助手）。
 * - 首页搜索入口是无文字图标（id=nsi），不是"搜索"文字按钮。
 * - 搜索页 EditText id=lnx，hint="搜寻"。
 *
 * 鲁棒性设计：
 * - 每步操作前先确保企微在前台 + 主界面（通过 launcher intent 拉起 + 按 back 退出子页）。
 * - 所有控件查找都有轮询重试，界面加载慢不会立即失败。
 * - 群名匹配支持繁简转换（用户设简体，界面显示繁体也能匹配）。
 */
class WeWorkAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    /**
     * 执行一次完整发送。返回状态字符串。
     * 每一步都打日志（TAG=WeWorkA11y），方便用 `adb logcat -s WeWorkA11y` 定位失败点。
     */
    fun send(message: String, groupName: String): String {
        Log.i(TAG, "send: START groupName='$groupName' msgLen=${message.length}")

        // 1. 拉起企微并确保在主界面（不是聊天页/搜索页等子页）。
        Log.d(TAG, "send: step1 ensureWeWorkForeground")
        if (!ensureWeWorkForeground()) {
            Log.e(TAG, "send: FAIL timeout (WeWork not foreground)")
            return "timeout"
        }
        Log.d(TAG, "send: step1b ensureHomePage")
        if (!ensureHomePage()) {
            Log.e(TAG, "send: FAIL no_home")
            return "no_home"
        }
        Thread.sleep(500)

        // 2. 点击首页搜索入口（id=nsi）。
        Log.d(TAG, "send: step2 find search entry")
        val root = rootInActiveWindow ?: run {
            Log.e(TAG, "send: FAIL root null after home")
            return "timeout"
        }
        val searchEntry = findSearchEntry(root) ?: run {
            Log.e(TAG, "send: FAIL no_search_entry (dumping root texts)")
            dumpNodeTexts(root, 0)
            return "no_search_entry"
        }
        Log.d(TAG, "send: click search entry id=${searchEntry.viewIdResourceName}")
        if (!clickNode(searchEntry, "search_entry")) {
            Log.e(TAG, "send: FAIL click search entry")
            return "no_search_entry"
        }
        Thread.sleep(1200)

        // 3. 找搜索输入框（EditText id=lnx），填入群名。
        Log.d(TAG, "send: step3 find search box (EditText)")
        val searchBox = waitForNode(timeoutMs = 6000) { node ->
            node.className?.toString() == "android.widget.EditText" && node.isVisibleToUser
        } ?: run {
            Log.e(TAG, "send: FAIL no_search_box (dumping root after click)")
            rootInActiveWindow?.let { dumpNodeTexts(it, 0) }
            return "no_search_box"
        }
        Log.d(TAG, "send: set search text '$groupName' to box id=${searchBox.viewIdResourceName}")
        if (!setText(searchBox, groupName)) {
            Log.e(TAG, "send: FAIL setText search box")
            return "no_search_box"
        }
        Thread.sleep(2000)

        // 4. 在搜索结果中找匹配的群会话项。
        Log.d(TAG, "send: step4 find group result matching '$groupName'")
        val groupItem = waitForNode(timeoutMs = 8000) { node ->
            if (!node.isClickable || !node.isVisibleToUser) return@waitForNode false
            val texts = collectTexts(node, maxDepth = 5)
            texts.any { looseMatch(it, groupName) }
        } ?: run {
            Log.e(TAG, "send: FAIL no_group_result (dumping clickable items)")
            rootInActiveWindow?.let { dumpClickableTexts(it, 0) }
            return "no_group_result"
        }
        Log.d(TAG, "send: click group item")
        if (!clickNode(groupItem, "group_item")) {
            Log.e(TAG, "send: FAIL click group item")
            return "no_group_result"
        }

        // 4b. 验证已离开搜索页进入聊天页：等待搜索框 lnx 消失。
        Log.d(TAG, "send: step4b verify entered chat (wait lnx disappear)")
        val enteredChat = waitForCondition(timeoutMs = 5000) { root ->
            findNodeById(root, "com.tencent.wework:id/lnx", 12) == null
        }
        if (!enteredChat) {
            Log.e(TAG, "send: FAIL still on search page after click group (lnx still present)")
            return "no_chat_page"
        }
        Log.d(TAG, "send: entered chat page")
        Thread.sleep(1000)

        // 5. 找聊天页消息输入框（EditText）。排除搜索框 id=lnx，避免误填。
        Log.d(TAG, "send: step5 find message input box (exclude lnx)")
        val msgBox = waitForNode(timeoutMs = 6000) { node ->
            if (node.className?.toString() != "android.widget.EditText") return@waitForNode false
            if (!node.isVisibleToUser) return@waitForNode false
            // 排除搜索框 lnx
            if (node.viewIdResourceName == "com.tencent.wework:id/lnx") return@waitForNode false
            true
        } ?: run {
            Log.e(TAG, "send: FAIL no_input_box (all EditText are lnx?)")
            rootInActiveWindow?.let { dumpNodeTexts(it, 0) }
            return "no_input_box"
        }
        Log.d(TAG, "send: set message text (len=${message.length}) to input box")
        if (!setText(msgBox, message)) {
            Log.e(TAG, "send: FAIL setText message box")
            return "no_input_box"
        }
        // 填入文字后等待 IME 布局稳定，发送按钮才会渲染出来。
        Thread.sleep(1500)

        // 6. 轮询找发送按钮（"傳送"/"發送"/"发送"/"Send"）。
        // IME 弹出后 rootInActiveWindow 节点树会刷新，文字可能短暂丢失，需要轮询等待。
        Log.d(TAG, "send: step6 find send button (polling 6s)")
        val sendBtn = waitForNode(timeoutMs = 6000) { node ->
            findSendButtonByText(node) != null
        }?.let { findSendButtonByText(it) }
        if (sendBtn == null) {
            Log.e(TAG, "send: FAIL no_send_button (dumping texts)")
            rootInActiveWindow?.let { dumpNodeTexts(it, 0) }
            return "no_send_button"
        }
        Log.d(TAG, "send: click send button")
        val ok = clickNode(sendBtn, "send_button")
        if (ok) {
            Log.i(TAG, "send: SUCCESS")
            return "sent"
        }
        Log.e(TAG, "send: FAIL click send button")
        return "no_send_button"
    }

    /** 在给定 root 中按文字/desc 找发送按钮。 */
    private fun findSendButtonByText(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val targets = listOf("傳送", "發送", "发送", "Send")
        for (target in targets) {
            val node = findNodeByText(root, target, 12)
            if (node != null) return findClickableAncestor(node) ?: node
            val descNode = findNodeByContentDesc(root, target, 12)
            if (descNode != null) return findClickableAncestor(descNode) ?: descNode
        }
        return null
    }

    /**
     * 点击节点。先试 performAction(ACTION_CLICK)，失败（NAF 节点常见）则用
     * dispatchGesture 在节点中心坐标模拟一次真实点击。
     */
    private fun clickNode(node: AccessibilityNodeInfo?, tag: String): Boolean {
        if (node == null) return false
        if (node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
            Log.d(TAG, "clickNode[$tag]: performAction OK id=${node.viewIdResourceName}")
            return true
        }
        val r = Rect()
        node.getBoundsInScreen(r)
        val x = r.exactCenterX()
        val y = r.exactCenterY()
        Log.w(TAG, "clickNode[$tag]: performAction failed, fallback gesture at ($x,$y) bounds=$r")
        return dispatchGestureClick(x, y)
    }

    /** 在屏幕坐标模拟一次点击手势。 */
    private fun dispatchGestureClick(x: Float, y: Float): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 80)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        val latch = CountDownLatch(1)
        var ok = false
        val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(g: GestureDescription?) { ok = true; latch.countDown() }
            override fun onCancelled(g: GestureDescription?) { ok = false; latch.countDown() }
        }, null)
        if (!dispatched) {
            Log.e(TAG, "dispatchGestureClick: dispatchGesture returned false")
            return false
        }
        latch.await(2, TimeUnit.SECONDS)
        Log.d(TAG, "dispatchGestureClick: completed=$ok at ($x,$y)")
        return ok
    }

    /** 调试用：递归打印节点文字，定位找不到控件时界面上实际有什么。 */
    private fun dumpNodeTexts(node: AccessibilityNodeInfo?, depth: Int) {
        if (node == null || depth > 10) return
        val text = node.text?.toString().orEmpty()
        val desc = node.contentDescription?.toString().orEmpty()
        val id = node.viewIdResourceName.orEmpty()
        if (text.isNotEmpty() || desc.isNotEmpty() || id.isNotEmpty()) {
            Log.d(TAG, "  ".repeat(depth) + "[$id] text='$text' desc='$desc' clickable=${node.isClickable}")
        }
        for (i in 0 until node.childCount) {
            dumpNodeTexts(node.getChild(i), depth + 1)
        }
    }

    /** 调试用：只打印可见且可点击的节点文字（找群结果用）。 */
    private fun dumpClickableTexts(node: AccessibilityNodeInfo?, depth: Int) {
        if (node == null || depth > 10) return
        if (node.isClickable && node.isVisibleToUser) {
            val texts = collectTexts(node, 3)
            if (texts.isNotEmpty()) {
                Log.d(TAG, "clickable: $texts id=${node.viewIdResourceName}")
            }
        }
        for (i in 0 until node.childCount) {
            dumpClickableTexts(node.getChild(i), depth + 1)
        }
    }

    // ---- 鲁棒性：确保企微在前台 + 主界面 ----

    /** 拉起企微到前台。用 getLaunchIntentForPackage 避免直接指定未 exported 的 component 导致 Permission Denial。 */
    private fun ensureWeWorkForeground(): Boolean {
        Log.d(TAG, "ensureWeWorkForeground: start intent")
        val intent = packageManager.getLaunchIntentForPackage("com.tencent.wework")
        if (intent == null) {
            Log.e(TAG, "ensureWeWorkForeground: getLaunchIntentForPackage returned null")
            return isWeWorkForeground()
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        try {
            startActivity(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "ensureWeWorkForeground: startActivity failed: ${t.message}")
        }
        // 轮询等待企微成为前台。
        val deadline = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < deadline) {
            if (isWeWorkForeground()) {
                Log.d(TAG, "ensureWeWorkForeground: WeWork is foreground")
                return true
            }
            Thread.sleep(300)
        }
        Log.e(TAG, "ensureWeWorkForeground: timeout waiting for foreground")
        return false
    }

    private fun isWeWorkForeground(): Boolean {
        // AccessibilityService 没有直接 API 取前台包名；用 rootInActiveWindow 的包名推断。
        val root = rootInActiveWindow ?: return false
        // 检查节点包名是否是 com.tencent.wework。
        return root.packageName?.toString() == "com.tencent.wework"
    }

    /**
     * 确保企微在主界面（消息列表页），不在聊天页/搜索页等子页。
     * 主界面标识：底部 tab "訊息"/"消息" 存在（id=nrr 或文字匹配）。
     * 如果在子页，按 back 键逐级退出到主界面。
     *
     * 鲁棒性：按 back 退到某层时企微可能弹出过渡界面/黑屏遮罩，rootInActiveWindow
     * 返回 null。此时不能死等，需要重新拉起企微前台（再发 launcher intent）跳出黑屏。
     */
    private fun ensureHomePage(): Boolean {
        var nullStreak = 0 // 连续 root null 次数，超过阈值则重新拉起前台
        // 最多尝试 10 次（按 back + 重新拉起）。
        for (attempt in 0 until 10) {
            val root = rootInActiveWindow
            if (root == null) {
                nullStreak++
                Log.d(TAG, "ensureHomePage: attempt $attempt root null (streak=$nullStreak)")
                if (nullStreak >= 2) {
                    // 连续 2 次 root null，可能卡在黑屏过渡页，重新拉起企微前台。
                    Log.d(TAG, "ensureHomePage: re-launch WeWork to escape black screen")
                    ensureWeWorkForeground()
                    nullStreak = 0
                } else {
                    Thread.sleep(500)
                }
                continue
            }
            nullStreak = 0
            if (isHomePage(root)) {
                Log.d(TAG, "ensureHomePage: at home (attempt $attempt)")
                return true
            }
            // 不在主界面，按 back 退一层。
            Log.d(TAG, "ensureHomePage: attempt $attempt not home, press BACK")
            performGlobalAction(GLOBAL_ACTION_BACK)
            Thread.sleep(700)
        }
        // 最后再检查一次。
        val root = rootInActiveWindow ?: run {
            Log.e(TAG, "ensureHomePage: final root null")
            return false
        }
        val ok = isHomePage(root)
        Log.d(TAG, "ensureHomePage: final check ok=$ok")
        return ok
    }

    /**
     * 判断是否在主界面。
     * 主界面特征：底部 tab "訊息"/"消息" 存在（id=nrr），
     * 或顶部搜索入口 id=nsi 存在。
     */
    private fun isHomePage(root: AccessibilityNodeInfo): Boolean {
        // 快速检查：id=nsi（搜索入口）存在即主界面。
        if (findNodeById(root, "com.tencent.wework:id/nsi", 8) != null) return true
        // Fallback：底部 tab "訊息"/"消息" 文字。
        val tabs = listOf("訊息", "消息")
        for (tab in tabs) {
            if (findNodeByText(root, tab, 12) != null) return true
        }
        return false
    }

    // ---- 控件查找 ----

    /** 找首页搜索入口。优先 id=nsi（深度足够才能命中），fallback 位置定位（顶部右侧窄图标）。 */
    private fun findSearchEntry(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        // nsi 埋得较深（约第10层），深度必须给足。
        val byId = findNodeById(root, "com.tencent.wework:id/nsi", 15)
        if (byId?.isClickable == true) return byId
        Log.w(TAG, "findSearchEntry: nsi not found by id (depth=15), fallback to position. byId=$byId")
        // Fallback：顶部 15% 区域、宽度不超过屏幕 25% 的无文字 clickable 节点。
        // （排除用户信息卡片 owk 那种占满宽度的节点）
        val rect = Rect()
        root.getBoundsInScreen(rect)
        val topThreshold = rect.height() * 0.15
        val maxWidth = rect.width() * 0.25
        return findMatching(root, { node ->
            if (!node.isClickable || !node.isVisibleToUser) return@findMatching false
            val r = Rect()
            node.getBoundsInScreen(r)
            if (r.top > topThreshold) return@findMatching false
            if (r.width() > maxWidth) return@findMatching false
            // 搜索图标无文字；排除有文字的 tab（如"訊息"）。
            node.text?.isNotEmpty() != true
        }, 15)
    }

    private fun findNodeById(root: AccessibilityNodeInfo?, id: String, maxDepth: Int): AccessibilityNodeInfo? {
        if (root == null || maxDepth < 0) return null
        if (root.viewIdResourceName == id) return root
        for (i in 0 until root.childCount) {
            val found = findNodeById(root.getChild(i), id, maxDepth - 1)
            if (found != null) return found
        }
        return null
    }

    private fun findNodeByText(root: AccessibilityNodeInfo?, text: String, maxDepth: Int): AccessibilityNodeInfo? {
        if (root == null || maxDepth < 0) return null
        if (root.text?.toString()?.equals(text) == true) return root
        for (i in 0 until root.childCount) {
            val found = findNodeByText(root.getChild(i), text, maxDepth - 1)
            if (found != null) return found
        }
        return null
    }

    private fun findNodeByContentDesc(root: AccessibilityNodeInfo?, desc: String, maxDepth: Int): AccessibilityNodeInfo? {
        if (root == null || maxDepth < 0) return null
        if (root.contentDescription?.toString()?.equals(desc) == true) return root
        for (i in 0 until root.childCount) {
            val found = findNodeByContentDesc(root.getChild(i), desc, maxDepth - 1)
            if (found != null) return found
        }
        return null
    }

    /** 收集节点及其子节点的所有文字。 */
    private fun collectTexts(root: AccessibilityNodeInfo?, maxDepth: Int): List<String> {
        if (root == null || maxDepth < 0) return emptyList()
        val result = mutableListOf<String>()
        root.text?.toString()?.let { if (it.isNotEmpty()) result.add(it) }
        root.contentDescription?.toString()?.let { if (it.isNotEmpty()) result.add(it) }
        for (i in 0 until root.childCount) {
            result.addAll(collectTexts(root.getChild(i), maxDepth - 1))
        }
        return result
    }

    /**
     * 宽松匹配群名。企微界面可能是繁体，用户设置可能是简体。
     * 去掉标点空格后比较，并支持包含关系。
     */
    private fun looseMatch(displayText: String, target: String): Boolean {
        if (displayText.isEmpty() || target.isEmpty()) return false
        val normDisplay = normalize(displayText)
        val normTarget = normalize(target)
        if (normDisplay == normTarget) return true
        val simpDisplay = toSimplified(normDisplay)
        val simpTarget = toSimplified(normTarget)
        if (simpDisplay == simpTarget) return true
        if (simpDisplay.contains(simpTarget) || simpTarget.contains(simpDisplay)) return true
        return false
    }

    private fun normalize(s: String): String {
        return s.replace(Regex("[\\s\\p{Punct}（）()\\[\\]【】{}<>《》\"'·、，。！？；：]+"), "")
    }

    /** 繁体转简体（覆盖企微常见字）。 */
    private fun toSimplified(s: String): String {
        val map = mapOf(
            '檔' to '档', '傳' to '传', '輸' to '输', '訊' to '讯', '尋' to '寻',
            '發' to '发', '聯' to '联', '絡' to '络', '記' to '记', '錄' to '录',
            '郵' to '邮', '設' to '设', '業' to '业', '會' to '会', '議' to '议',
            '別' to '别', '碼' to '码', '電' to '电', '話' to '话', '號' to '号',
            '員' to '员', '務' to '务', '報' to '报', '導' to '导', '體' to '体',
            '統' to '统', '關' to '关', '於' to '于', '資' to '资', '師' to '师',
            '場' to '场', '產' to '产', '經' to '经', '營' to '营', '銷' to '销',
            '後' to '后', '財' to '财', '術' to '术', '開' to '开', '網' to '网',
            '頁' to '页', '線' to '线', '載' to '载', '個' to '个', '當' to '当',
            '節' to '节', '點' to '点', '預' to '预', '進' to '进', '現' to '现',
            '問' to '问', '題' to '题', '討' to '讨', '論' to '论', '計' to '计',
            '製' to '制', '蹤' to '踪', '項' to '项', '標' to '标', '準' to '准',
            '則' to '则', '規' to '规', '範' to '范', '優' to '优', '測' to '测',
            '試' to '试', '檢' to '检', '復' to '复', '錯' to '错', '誤' to '误',
            '過' to '过', '結' to '结', '總' to '总', '告' to '告', '彙' to '汇',
            '紀' to '纪', '劃' to '划', '執' to '执', '評' to '评', '審' to '审',
            '核' to '核', '驗' to '验', '證' to '证', '確' to '确', '認' to '认',
            '協' to '协', '調' to '调', '溝' to '沟', '匯' to '汇', '編' to '编',
            '輯' to '辑', '刪' to '删'
        )
        return s.map { map[it] ?: it }.joinToString("")
    }

    private fun findClickableAncestor(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var cur = node
        while (cur != null) {
            if (cur.isClickable) return cur
            cur = cur.parent
        }
        return null
    }

    private fun waitForNode(
        timeoutMs: Long,
        predicate: (AccessibilityNodeInfo) -> Boolean,
    ): AccessibilityNodeInfo? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val root = rootInActiveWindow ?: run {
                Thread.sleep(300)
                continue
            }
            val found = findMatching(root, predicate, 12)
            if (found != null) return found
            Thread.sleep(300)
        }
        return null
    }

    /** 轮询等待某个条件成立（基于 root 节点判断）。 */
    private fun waitForCondition(
        timeoutMs: Long,
        predicate: (AccessibilityNodeInfo) -> Boolean,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val root = rootInActiveWindow
            if (root != null && predicate(root)) return true
            Thread.sleep(300)
        }
        return false
    }

    private fun findMatching(
        root: AccessibilityNodeInfo,
        predicate: (AccessibilityNodeInfo) -> Boolean,
        maxDepth: Int,
    ): AccessibilityNodeInfo? {
        if (maxDepth < 0) return null
        if (predicate(root)) return root
        for (i in 0 until root.childCount) {
            val child = root.getChild(i) ?: continue
            val found = findMatching(child, predicate, maxDepth - 1)
            if (found != null) return found
        }
        return null
    }

    private fun setText(node: AccessibilityNodeInfo, text: String): Boolean {
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return true
        val clipboard = getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                as android.content.ClipboardManager
        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("msg", text))
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        return node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
    }

    companion object {
        private const val TAG = "WeWorkA11y"

        @Volatile
        private var instance: WeWorkAccessibilityService? = null

        fun isEnabled(): Boolean = instance != null

        fun startSend(message: String, groupName: String): String {
            val service = instance ?: run {
                Log.e(TAG, "startSend: no_accessibility (service not connected)")
                return "no_accessibility"
            }
            Log.i(TAG, "startSend: invoke send() groupName='$groupName'")
            val result = AtomicReference("timeout")
            val latch = CountDownLatch(1)
            Thread {
                try {
                    result.set(service.send(message, groupName))
                } catch (t: Throwable) {
                    Log.e(TAG, "startSend: EXCEPTION ${t.javaClass.simpleName}: ${t.message}", t)
                    result.set("error:" + t.javaClass.simpleName)
                } finally {
                    latch.countDown()
                }
            }.start()
            val finished = latch.await(50, TimeUnit.SECONDS)
            if (!finished) {
                Log.e(TAG, "startSend: TIMEOUT after 50s")
                return "timeout"
            }
            Log.i(TAG, "startSend: result=${result.get()}")
            return result.get()
        }
    }
}
