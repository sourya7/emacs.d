| Name | Identifier | Description | Status | Owner | Repository | Documentation | Escaped pipe | Code span | Unicode | Last updated | Notes |
|:---|---:|:---|:---:|---|---|---|---|---|:---:|---:|---|
| Parser | parser-abcdefghijklmnopqrstuvwxyz-001 | Parse ordinary Markdown pipe tables without changing their source text. | ready | Ada Lovelace | https://example.test/projects/pichat/table-parser | https://example.test/docs/markdown/tables/parser-and-layout | left \| right | `alpha|beta` | λ 東京 🚀 | 2026-07-30 | This deliberately long cell should be ellipsized in the bounded inline preview but remain complete in the viewer. |
| Layout | layout-abcdefghijklmnopqrstuvwxyz-002 | Allocate short columns first and share the remaining display width fairly. | active | Grace Hopper | https://example.test/projects/pichat/table-layout | https://example.test/docs/markdown/tables/width-allocation | one \| two \| three | ``value ` with | pipe`` | naïve café 🧪 | 2026-07-31 | abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-unbroken-value |
| Viewer | viewer-abcdefghijklmnopqrstuvwxyz-003 | Open a complete read-only Org table snapshot with horizontal scrolling. | planned | Margaret Hamilton | https://example.test/projects/pichat/table-viewer | https://example.test/docs/markdown/tables/org-viewer | source \| snapshot | `org|table` | Ελληνικά 中文 🌍 | 2026-08-01 | The originating chat may reproject or die while this immutable snapshot remains readable. |
| Cache | cache-abcdefghijklmnopqrstuvwxyz-004 | Reuse position-independent parsing and layout while bounding retained memory. | review | Barbara Liskov | https://example.test/projects/pichat/table-cache | https://example.test/docs/markdown/tables/cache-invalidation | digest \| width | `source|width|policy` | résumé 한국어 📦 | 2026-08-02 | Resizing should rerender only tables whose computed target width actually changed. |
| Fallback | fallback-abcdefghijklmnopqrstuvwxyz-005 | Leave malformed or unsupported candidates as readable raw Markdown. | ready | Radia Perlman | https://example.test/projects/pichat/table-fallback | https://example.test/docs/markdown/tables/failure-isolation | fail \| open | `raw|source` | español العربية 🛟 | 2026-08-03 | Presentation errors must never roll back an otherwise valid transcript projection. |

```markdown
| This | looks | like | a table |
|---|---|---|---|
| but | remains | fenced | code |
```
