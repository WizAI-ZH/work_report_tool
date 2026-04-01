#!/usr/bin/env python3
# 测试调试输出功能

print("=== 测试调试输出 ===")
print("测试print语句是否正常工作")

# 模拟AI建议功能的调试输出
def test_ai_debug():
    print("\n=== 开始AI建议功能 ===")
    print("今日工作内容: 测试工作 (50%, 已完成部分工作, 明天继续")
    print("明日计划内容: 休息")
    print("用户是否明确写了'休息': True")
    print("用户明确写了'休息'，直接按照休息处理")
    print("构建休息模式的提示词")
    print("生成的提示词: 请优化以下工作汇报内容...")
    print("调用API: https://api.chatanywhere.tech/v1/chat/completions")
    print("使用模型: deepseek-v3.2")
    print("开始发送API请求...")
    print("API响应状态码: 200")
    print("AI生成内容: 1、今日工作完成情况；\na. 测试工作 (50%, 已完成部分工作, 明天继续)\n\n2、明日工作计划；\n休息")

if __name__ == "__main__":
    test_ai_debug()
    print("\n=== 测试完成 ===")
