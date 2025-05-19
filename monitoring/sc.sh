#!/bin/bash

set -e

# Названия веток
OLD_BRANCH="old-main"
TEMP_BRANCH="temp-squash"
TARGET_BRANCH="main"

## Проверка на наличие uncommitted изменений
#if [[ -n $(git status --porcelain) ]]; then
#  echo "❌ У тебя есть незакоммиченные изменения. Сначала закоммить или stash."
#  exit 1
#fi

echo "📦 Переключаюсь на ветку $TARGET_BRANCH"
git checkout $TARGET_BRANCH

echo "🌿 Создаю временную ветку $TEMP_BRANCH"
git checkout -b $TEMP_BRANCH

echo "🔁 Выполняю soft reset до самого первого коммита"
git reset --soft $(git rev-list --max-parents=0 HEAD)

echo "✅ Делаю один новый коммит со всеми изменениями"
git commit -m "Initial commit"

echo "🛑 Переименовываю текущую ветку $TARGET_BRANCH в $OLD_BRANCH как резервную"
git branch -M $TARGET_BRANCH $OLD_BRANCH

echo "📌 Переименовываю $TEMP_BRANCH в $TARGET_BRANCH"
git branch -m $TEMP_BRANCH $TARGET_BRANCH

echo "🚀 Форс-пуш в origin/$TARGET_BRANCH"
git push -f origin $TARGET_BRANCH

echo "🧹 Удаляю резервную ветку $OLD_BRANCH локально"
git branch -D $OLD_BRANCH

echo "🧼 Пытаюсь удалить ветку $OLD_BRANCH на GitHub (если она существует)"
git push origin --delete $OLD_BRANCH || echo "ℹ️ Ветка $OLD_BRANCH не найдена в origin, пропускаю"

echo "✅ Готово! Ветка $TARGET_BRANCH теперь содержит только один коммит, резерв удалён."