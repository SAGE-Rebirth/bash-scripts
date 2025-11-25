#!/bin/bash
set -euo pipefail

# ========== CONFIGURATION ==========
IGNORE_ORG="techblueera"
IGNORE_REPO="docker_files_microservices"
TARGET_BRANCHES=("main" "staging" "prod-staging")
DRY_RUN=false
# ====================================

# Parse args
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "🔍 Running in DRY-RUN mode — no files will be deleted or pushed."
fi

# Ensure git uses gh token for all future commands (one-time global config)
git config --global credential.helper "!gh auth git-credential"

# Check dependencies
for cmd in git gh; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ $cmd is not installed. Please install it first."
        exit 1
    fi
done

# Check GitHub login
if ! gh auth status &> /dev/null; then
    echo "❌ Not logged into GitHub CLI. Run: gh auth login"
    exit 1
fi

echo "✅ Git & gh ready. Fetching organizations..."
orgs=$(gh api user/orgs --jq '.[].login')
if [ -z "$orgs" ]; then
    echo "⚠ No organizations found."
    exit 1
fi

echo "Select an organization:"
select org in $orgs; do
    [[ -n "$org" ]] && break
    echo "❌ Invalid choice, try again."
done

repos=$(gh repo list "$org" --limit 1000 --json name --jq '.[].name')
if [ -z "$repos" ]; then
    echo "⚠ No repositories found in $org."
    exit 1
fi

if [ "$DRY_RUN" = false ]; then
    read -p "⚠ This will delete ONLY Dockerfiles from branches ${TARGET_BRANCHES[*]} in $org (excluding $IGNORE_ORG/$IGNORE_REPO). Continue? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && echo "❌ Cancelled." && exit 0
fi

for repo in $repos; do
    if [[ "$org" == "$IGNORE_ORG" && "$repo" == "$IGNORE_REPO" ]]; then
        echo "⏩ Skipping ignored repo: $org/$repo"
        continue
    fi

    echo "🔄 Processing $org/$repo..."
    gh repo clone "$org/$repo" -- --quiet || { echo "❌ Failed to clone $org/$repo"; continue; }
    cd "$repo" || { echo "❌ Failed to enter $repo directory"; cd ..; continue; }

    for branch in "${TARGET_BRANCHES[@]}"; do
        if git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
            echo "   📂 Branch found: $branch"
            git fetch origin "$branch" --quiet
            if [ "$DRY_RUN" = false ]; then
                git checkout "$branch" &>/dev/null
                git reset --hard origin/"$branch" &>/dev/null
            else
                git checkout "$branch" &>/dev/null
            fi

            found_files=$(find . -type f -iname "Dockerfile")
            if [ -n "$found_files" ]; then
                while IFS= read -r file; do
                    echo "      🗑 Would delete: $file"
                    if [ "$DRY_RUN" = false ]; then
                        rm -f "$file"
                        git rm -f --cached "$file" >/dev/null 2>&1 || true
                    fi
                done <<< "$found_files"

                if [ "$DRY_RUN" = false ]; then
                    git add -u
                    git commit -m "Remove Dockerfiles" --allow-empty >/dev/null 2>&1 || true
                    git push origin "$branch"
                    echo "      ✅ Changes pushed to $branch"
                fi
            else
                echo "      ℹ No Dockerfiles in $branch"
            fi
        else
            echo "   ⚠ Branch $branch not found in $repo"
        fi
    done

    cd ..
    rm -rf "$repo"
done

if [ "$DRY_RUN" = true ]; then
    echo "✅ DRY-RUN complete. No changes were made."
else
    echo "🎯 Done. All non-ignored repos processed safely."
fi
