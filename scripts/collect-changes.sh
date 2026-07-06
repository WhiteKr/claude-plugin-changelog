#!/usr/bin/env bash
# skill:changelog - deterministic git plumbing for changelog generation
# Usage: bash collect-changes.sh [<from_ref>] [<to_ref>]
#
# <from_ref> 가 비어있으면 <to_ref> 에서 도달 가능한 가장 가까운 태그를 찾는다.
# 태그가 전혀 없으면 BASE_NOT_FOUND 를 출력하고 종료한다 (호출자가 사용자에게
# 범위를 물어 구체적인 ref 로 재호출해야 한다).
#
# 의도적으로 `set -e` 를 쓰지 않는다 — 개별 git 명령의 실패를 잡아 분류해야
# 하므로 첫 실패에 즉시 종료되면 안 된다. `set -u` 만 유지.
set -u

FROM_REF="${1:-}"
TO_REF="${2:-HEAD}"

# --- TO_REF 검증 ------------------------------------------------------------
TO_SHA=$(git rev-parse --verify "$TO_REF" 2>/dev/null)
if [ -z "$TO_SHA" ]; then
  echo "INVALID_REF:$TO_REF"
  exit 1
fi

# --- FROM_REF 결정 -----------------------------------------------------------
if [ -z "$FROM_REF" ]; then
  FROM_REF=$(git describe --tags --abbrev=0 "$TO_REF" 2>/dev/null)
  if [ -z "$FROM_REF" ]; then
    echo "BASE_NOT_FOUND"
    exit 0
  fi
fi

FROM_SHA=$(git rev-parse --verify "$FROM_REF" 2>/dev/null)
if [ -z "$FROM_SHA" ]; then
  echo "INVALID_REF:$FROM_REF"
  exit 1
fi

echo "BASE:$FROM_REF"
echo "HEAD:$TO_SHA"

# --- 메인 레포 커밋 -----------------------------------------------------------
echo "COMMITS_START"
git log --no-merges --format="%H|%an|%ar|%s" "$FROM_SHA".."$TO_SHA" 2>/dev/null
echo "COMMITS_END"

# --- 메인 레포 diff: 커밋 메시지만으로 카테고리를 추측하지 않도록 실제 변경 --
# 내용을 함께 제공한다. stat 은 파일 단위라 생략 없이 전체를 보여주고, unified
# diff 는 500줄에서 잘라(대용량 범위 대비) 실제 코드 변경의 성격을 파악할
# 근거로 쓴다.
echo "STAT_START"
git diff --stat "$FROM_SHA" "$TO_SHA" 2>/dev/null
echo "STAT_END"

echo "DIFF_START"
git diff --no-color "$FROM_SHA" "$TO_SHA" 2>/dev/null |
  awk 'NR<=500; NR==501 { print "[... diff가 길어 500줄에서 잘림 ...]"; exit }'
echo "DIFF_END"

# --- Submodule(gitlink) 변경 탐지 --------------------------------------------
# mode 160000 = gitlink. raw diff 형식: ":100644 160000 <old> <new> M\t<path>"
git diff --raw "$FROM_SHA" "$TO_SHA" 2>/dev/null | grep '^:.*160000' |
while IFS= read -r line; do
  SUB_OLD=$(echo "$line" | awk '{print $3}')
  SUB_NEW=$(echo "$line" | awk '{print $4}')
  SUB_PATH=$(echo "$line" | sed -E 's/^.*\t//')

  echo "SUBMODULE_START"
  echo "PATH:$SUB_PATH"
  echo "OLD:$SUB_OLD"
  echo "NEW:$SUB_NEW"

  if [ ! -d "$SUB_PATH" ]; then
    echo "SUBMODULE_UNAVAILABLE:directory not found"
    echo "SUBMODULE_END"
    continue
  fi

  # 서브모듈 안에서 old/new 오브젝트가 이미 있는지 확인. 없으면 한 번 fetch 시도.
  if ! git -C "$SUB_PATH" cat-file -e "$SUB_OLD" 2>/dev/null || \
     ! git -C "$SUB_PATH" cat-file -e "$SUB_NEW" 2>/dev/null; then
    git -C "$SUB_PATH" fetch --all --quiet 2>/dev/null
  fi

  if git -C "$SUB_PATH" cat-file -e "$SUB_OLD" 2>/dev/null && \
     git -C "$SUB_PATH" cat-file -e "$SUB_NEW" 2>/dev/null; then
    echo "SUBCOMMITS_START"
    git -C "$SUB_PATH" log --no-merges --format="%H|%an|%ar|%s" "$SUB_OLD".."$SUB_NEW" 2>/dev/null
    echo "SUBCOMMITS_END"

    echo "SUBSTAT_START"
    git -C "$SUB_PATH" diff --stat "$SUB_OLD" "$SUB_NEW" 2>/dev/null
    echo "SUBSTAT_END"

    echo "SUBDIFF_START"
    git -C "$SUB_PATH" diff --no-color "$SUB_OLD" "$SUB_NEW" 2>/dev/null |
      awk 'NR<=500; NR==501 { print "[... diff가 길어 500줄에서 잘림 ...]"; exit }'
    echo "SUBDIFF_END"
  else
    echo "SUBMODULE_UNAVAILABLE:objects not fetchable"
  fi
  echo "SUBMODULE_END"
done
