#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Fetch GitHub Token from environment variable
if [[ -z "$PAT_TOKEN" ]]; then
    echo -e "${RED}Error: PAT_TOKEN environment variable is not set. Exiting.${NC}"
    exit 1
fi

GITHUB_TOKEN="$PAT_TOKEN"

# Start execution time tracking
start_time=$(date +%s)

if ! command -v jq > /dev/null; then
    echo -e "${RED}Error: jq is not installed.${NC}" >&2
    exit 1
fi

# Check rate limit
rate_limit_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/rate_limit")
remaining=$(echo "$rate_limit_response" | jq -r '.rate.remaining // 0')
reset_time=$(echo "$rate_limit_response" | jq -r '.rate.reset // 0')

if [[ "$remaining" -eq 0 ]]; then
    reset_time_human=$(date -d "@$reset_time" "+%Y-%m-%d %H:%M:%S")
    echo -e "${RED}Rate limit exceeded. Try again after: $reset_time_human${NC}"
    exit 1
fi

input="cyber"
topic=$(echo "$input" | tr '[:upper:]' '[:lower:]' | tr " " "+")

echo -e "${YELLOW}Fetching repository information for topic: ${GREEN}${input}${NC}"
response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/search/repositories?q=stars%3A%3E50+$topic+sort:stars&per_page=5")

if ! echo "$response" | jq -e . > /dev/null 2>&1; then
    echo -e "${RED}Error: Failed to fetch data from GitHub API. Please check your internet connection or GitHub token.${NC}"
    exit 1
fi

tpc=$(echo "$response" | jq -r '.total_count // 0')
if [[ "$tpc" -eq 0 ]]; then
    echo -e "${RED}No repositories found for the topic '${input}'.${NC}"
    exit 1
fi

pg=$(( (tpc + 99) / 100 ))

repos_analyzed=0
repos_retrieved=0
pages_processed=0
empty_pages=0

rm -f README.md

cat <<EOF > README.md
# **Git-WatchTower**

Eyes on cybersecurity repositories! 

---


## **Summary of the Analysis**

| Metric                    | Value                   |
|---------------------------|-------------------------|
| Execution Date            | $(date '+%Y-%m-%d %H:%M:%S') |
| Repositories Analyzed     | <REPOS_ANALYZED>       |


---

## **Top Cybersecurity Repositories (Updated: $(date '+%Y-%m-%d'))**

| Repository (Link) | Stars   | Forks   | Description                     | Last Updated |
|-------------------|---------|---------|---------------------------------|--------------|
EOF

# Iterate through pages
for i in $(seq 1 "$pg"); do
    pages_processed=$((pages_processed + 1))

    page_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/search/repositories?q=stars%3A%3E50+$topic+sort:stars&per_page=100&page=$i")

    # Check if the page has items
    item_count=$(echo "$page_response" | jq '.items | length')
    if [[ "$item_count" -eq 0 || "$item_count" == "null" ]]; then
        empty_pages=$((empty_pages + 1))
        # Stop if we see 3 consecutive empty pages
        if [[ $empty_pages -ge 3 ]]; then
            break
        fi
        continue
    else
        empty_pages=0
    fi

    #
    # IMPORTANT: Use while-read redirection instead of a pipe
    # so increments happen in the current shell, not a subshell.
    #
    while read -r line; do
        repos_analyzed=$((repos_analyzed + 1))

        name=$(echo "$line" | jq -r '.name // "Unknown"')
        owner=$(echo "$line" | jq -r '.owner.login // "Unknown"')
        stars=$(echo "$line" | jq -r '.stargazers_count // 0')
        forks=$(echo "$line" | jq -r '.forks_count // 0')
        desc=$(echo "$line" | jq -r '.description // "No description"')
        updated=$(echo "$line" | jq -r '.updated_at // "1970-01-01T00:00:00Z"')
        url=$(echo "$line" | jq -r '.html_url // "#"')

        repos_retrieved=$((repos_retrieved + 1))

        short_desc=$(echo "$desc" | cut -c 1-50)
        if [ ${#desc} -gt 50 ]; then
          short_desc="$short_desc..."
        fi

        # Convert updated date to YYYY-MM-DD (UTC)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            updated_date=$(echo "$updated" | \
                           awk '{print $1}' | \
                           xargs -I {} date -u -jf "%Y-%m-%dT%H:%M:%SZ" {} "+%Y-%m-%d")
        else
            updated_date=$(date -d "$updated" "+%Y-%m-%d")
        fi

        printf "| [%s](%s) | %-7s | %-7s | %-31s | %-12s |\n" \
               "$name" "$url" "$stars" "$forks" "$short_desc" "$updated_date" \
               >> README.md
    done < <(echo "$page_response" | jq -c '.items[]')  # < <(...) is the key
done

#
# Replace placeholders in README
#
sed -i "s/<REPOS_ANALYZED>/$repos_analyzed/" README.md
sed -i "s/<REPOS_RETRIEVED>/$repos_retrieved/" README.md
sed -i "s/<PAGES_PROCESSED>/$pages_processed/" README.md
sed -i "s/<EMPTY_PAGES>/$empty_pages/" README.md

# Optionally print debug info to help troubleshooting
echo "DEBUG: repos_analyzed=$repos_analyzed"
echo "DEBUG: repos_retrieved=$repos_retrieved"
echo "DEBUG: pages_processed=$pages_processed"
echo "DEBUG: empty_pages=$empty_pages"

# Commit and push if README changed
if [ -s README.md ]; then
    git config --global user.email "github-actions@github.com"
    git config --global user.name "GitHub Actions Bot"
    git add README.md
    git commit -m "Update README with top repositories for '$input'"
    git push origin main
fi
