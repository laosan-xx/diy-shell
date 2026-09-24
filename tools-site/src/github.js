// GitHub 数据封装：运行时拉取 repo / latest release / README，并带 localStorage 缓存。
// 未登录 API 限流 60 次/小时/IP，缓存默认 1 小时以大幅降低请求。

const API = 'https://api.github.com'
const CACHE_TTL = 60 * 60 * 1000 // 1 小时
const CACHE_PREFIX = 'ghcache:'

function cacheKey(path) {
  return CACHE_PREFIX + path
}

async function cachedFetch(path) {
  const key = cacheKey(path)
  try {
    const raw = localStorage.getItem(key)
    if (raw) {
      const { t, data } = JSON.parse(raw)
      if (Date.now() - t < CACHE_TTL) return data
    }
  } catch (e) {
    /* 忽略缓存读取错误 */
  }

  const res = await fetch(`${API}${path}`, {
    headers: { Accept: 'application/vnd.github+json' },
  })
  if (!res.ok) throw new Error(`GitHub API ${res.status} @ ${path}`)
  const data = await res.json()

  try {
    localStorage.setItem(key, JSON.stringify({ t: Date.now(), data }))
  } catch (e) {
    /* 忽略写入错误（如隐私模式） */
  }
  return data
}

export async function getRepo(owner, repo) {
  return cachedFetch(`/repos/${owner}/${repo}`)
}

// 拉取 release 列表（含 pre-release，按发布时间倒序，第一条最新）。
// 优先返回最新的 pre-release；若仓库没有 pre-release，则回退到最新正式版。
export async function getLatestRelease(owner, repo) {
  const list = await cachedFetch(`/repos/${owner}/${repo}/releases?per_page=30`)
  if (!Array.isArray(list) || !list.length) return null
  const pre = list.find((r) => r.prerelease)
  return pre || list[0]
}

export async function getReadme(owner, repo, branch = 'main') {
  const res = await fetch(
    `https://raw.githubusercontent.com/${owner}/${repo}/${branch}/README.md`,
  )
  if (!res.ok) throw new Error(`README ${res.status}`)
  return await res.text()
}

// 把 JSON 里的基础工具信息，补全为包含 GitHub 实时数据的完整对象
export async function enrichTool(tool) {
  const result = { ...tool, repoValid: false }
  const [owner, repoName] = (tool.repo || '').split('/')
  if (!owner || !repoName) return result

  try {
    const [repo, release] = await Promise.all([
      getRepo(owner, repoName),
      getLatestRelease(owner, repoName).catch(() => null),
    ])

    result.repoValid = true
    result.description = tool.description || repo.description || ''
    result.icon = repo.social_preview_url || repo.owner?.avatar_url || ''
    result.stars = repo.stargazers_count
    result.htmlUrl = repo.html_url
    result.defaultBranch = repo.default_branch || 'main'

    if (release) {
      // 1) 剔除签名文件(.sig)与公钥(.asc)，这些对下载无用
      let assets = (release.assets || []).filter(
        (a) => !/\.(sig|asc)$/i.test(a.name) && !/public-key/i.test(a.name),
      )
      // 2) 按工具自定义关键字过滤（assetMatch 任一命中即保留）；未配置则保留全部
      if (Array.isArray(tool.assetMatch) && tool.assetMatch.length) {
        const matched = assets.filter((a) =>
          tool.assetMatch.some((k) => a.name.toLowerCase().includes(k.toLowerCase())),
        )
        if (matched.length) assets = matched
      }
      result.release = {
        tag: release.tag_name,
        publishedAt: release.published_at,
        url: release.html_url,
        assets: assets.map((a) => ({
          name: a.name,
          size: a.size,
          url: a.browser_download_url,
        })),
      }
    }
  } catch (e) {
    // 拉取失败：保留手动信息（name/description/manual/videos），页面仍可用
  }
  return result
}

// 将 github.com 下载链接替换为加速代理域名（形如 https://gh.xxx/owner/repo/...）
export function withProxy(url, domain) {
  if (!domain) return url
  return url.replace(/^https:\/\/github\.com\//i, `https://${domain}/`)
}

// 清空 GitHub 缓存，用于「刷新数据」按钮
export function clearGitHubCache() {
  try {
    Object.keys(localStorage)
      .filter((k) => k.startsWith(CACHE_PREFIX))
      .forEach((k) => localStorage.removeItem(k))
  } catch (e) {
    /* ignore */
  }
}
