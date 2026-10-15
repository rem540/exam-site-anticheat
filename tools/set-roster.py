# -*- coding: utf-8 -*-
"""从 roster.txt 重新生成 index.html / admin.html 中的名单数组。

用法：
    python tools/set-roster.py roster.txt

roster.txt 每行一个身份，推荐格式「班级-姓名」，例如：

    示例1班-测试01
    示例1班-测试02
    示例2班-测试03

如果一行里没有「-」，会按最后一个「班」字切分（兼容「26网络1班张三」这种写法）。
空行和以 # 开头的行会被忽略。
"""
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def split_one(line):
    if '-' in line:
        cls, name = line.rsplit('-', 1)
        return cls.strip(), name.strip()
    m = re.match(r'^(.*?班)(.+)$', line)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return line.strip(), ''


def build_roster(path):
    if not os.path.exists(path):
        sys.exit('找不到名单文件：%s' % path)
    roster, seen = [], set()
    for raw in io.open(path, encoding='utf-8'):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        cls, name = split_one(line)
        if not name or (cls, name) in seen:
            continue
        seen.add((cls, name))
        roster.append({'c': cls, 'n': name})
    roster.sort(key=lambda p: (p['c'], p['n']))
    return roster


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'roster.txt')
    roster = build_roster(src)
    if not roster:
        sys.exit('名单文件里没有解析出任何身份')

    payload = 'var ROSTER = %s;' % json.dumps(roster, ensure_ascii=False)
    for fn in ('index.html', 'admin.html'):
        path = os.path.join(ROOT, fn)
        if not os.path.exists(path):
            print('跳过（不存在）：%s' % fn)
            continue
        html = io.open(path, encoding='utf-8').read()
        new, n = re.subn(r'var ROSTER = \[.*?\];', payload, html, count=1, flags=re.S)
        if not n:
            print('跳过（没找到名单数组）：%s' % fn)
            continue
        io.open(path, 'w', encoding='utf-8').write(new)
        print('已更新 %-12s 共 %d 人' % (fn, len(roster)))
    print('完成：%d 个身份' % len(roster))


if __name__ == '__main__':
    main()
