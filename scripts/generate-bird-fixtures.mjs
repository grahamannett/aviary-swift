// Development-only oracle. Reads a Bird distribution; writes fixtures only in Aviary.
import { mkdirSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import { pathToFileURL } from "node:url"

if (!process.argv[2]) throw new Error("Usage: node scripts/generate-bird-fixtures.mjs /path/to/bird-copy")
const reference = resolve(process.argv[2])
const { mapTweetResult, unwrapTweetResult, renderContentState } = await import(
  pathToFileURL(`${reference}/dist/lib/twitter-client-utils.js`)
)
const { createCliContext } = await import(pathToFileURL(`${reference}/dist/cli/shared.js`))
const { createProgram } = await import(pathToFileURL(`${reference}/dist/cli/program.js`))
const { formatStatsLine } = await import(pathToFileURL(`${reference}/dist/lib/output.js`))
const tweet = (id, text) => ({
  rest_id: id,
  core: { user_results: { result: { rest_id: "author-1", legacy: { screen_name: "alice", name: "Alice" } } } },
  legacy: {
    full_text: text,
    created_at: "Tue Sep 22 13:27:42 +0000 2026",
    reply_count: 2,
    retweet_count: 3,
    favorite_count: 4,
    conversation_id_str: id,
  },
})
const photo = {
  type: "photo",
  media_url_https: "https://example.invalid/photo.jpg",
  sizes: { large: { w: 1200, h: 800 }, small: { w: 300, h: 200 } },
}
const quote = tweet("quote", "Quoted tweet\nwith a second line")
quote.legacy.extended_entities = { media: [photo] }
quote.quoted_status_result = { result: tweet("nested", "Nested quote") }
const main = tweet("main", " Main tweet ")
main.quoted_status_result = { result: { tweet: quote } }
const article = tweet("article", "Legacy preview")
article.article = {
  article_results: {
    result: {
      title: "A title",
      preview_text: "Preview",
      content_state: {
        blocks: [
          { type: "header-one", text: "A title" },
          { type: "unstyled", text: "A full article body" },
        ],
        entityMap: [],
      },
    },
  },
}
const plainArticle = tweet("plain-article", "Legacy preview")
plainArticle.article = { title: "Article title", plain_text: "The full body." }
const note = tweet("note", "Truncated text")
note.note_tweet = { note_tweet_results: { result: { content: { rich_text: { text: " Complete long text " } } } } }
const video = tweet("video", "Video")
video.legacy.extended_entities = {
  media: [
    {
      ...photo,
      type: "video",
      video_info: {
        duration_millis: 1500,
        variants: [
          { content_type: "application/x-mpegURL", url: "https://example.invalid/master.m3u8" },
          { content_type: "video/mp4", bitrate: 100, url: "https://example.invalid/low.mp4" },
          { content_type: "video/mp4", bitrate: 300, url: "https://example.invalid/high.mp4" },
        ],
      },
    },
  ],
}
const gif = tweet("gif", "GIF")
gif.legacy.entities = {
  media: [
    {
      ...photo,
      type: "animated_gif",
      video_info: { variants: [{ content_type: "video/mp4", url: "https://example.invalid/gif.mp4" }] },
    },
  ],
}
const nestedArticle = tweet("nested-article", "preview")
nestedArticle.article = { title: "Title", text: [{ text: "Nested body" }] }
const orderedArticle = tweet("ordered-article", "preview")
orderedArticle.article = { title: "Title", z: { text: "First paragraph" }, a: { text: "Second paragraph" } }
const emptyName = tweet("empty-name", "Text")
emptyName.core.user_results.result.legacy.name = ""
const emptyUser = tweet("empty-user", "Text")
emptyUser.core.user_results.result.legacy.screen_name = ""
const videoWithoutVariants = tweet("video-without-variants", "Video")
videoWithoutVariants.legacy.entities = { media: [{ ...photo, type: "video", video_info: { duration_millis: 1234 } }] }
const cases = [
  ["ordinary", tweet("ordinary", " Hello ")],
  ["quote", main],
  ["quote-disabled", main, 0],
  ["nested-raw", main, 2, true],
  ["article", article],
  ["plain-article", plainArticle],
  ["long-note", note],
  ["video", video],
  ["gif", gif],
  ["wrapped", { tweet: main }, 1, true],
  ["unavailable", { __typename: "TweetTombstone" }],
  ["empty-id", tweet("", "Text")],
  ["empty-user", emptyUser],
  ["empty-name", emptyName],
  ["nested-article", nestedArticle],
  ["ordered-article", orderedArticle],
  ["video-without-variants", videoWithoutVariants],
]
const mapping = cases.map(([name, input, quoteDepth = 1, includeRaw = false]) => ({
  name,
  input,
  quoteDepth,
  includeRaw,
  expected: mapTweetResult(unwrapTweetResult(input), { quoteDepth, includeRaw }) ?? null,
}))
const rich = [
  {
    blocks: [{ type: "unstyled", text: "😀 Read this link", entityRanges: [{ key: 0, offset: 13, length: 4 }] }],
    entityMap: { 0: { type: "LINK", data: { url: "https://example.invalid" } } },
  },
  {
    blocks: [
      { type: "ordered-list-item", text: "One" },
      { type: "ordered-list-item", text: "Two" },
      { type: "unstyled", text: "Break" },
      { type: "ordered-list-item", text: "Again" },
    ],
  },
  {
    blocks: ["MARKDOWN", "DIVIDER", "TWEET", "LINK", "IMAGE"].map((type, key) => ({
      type: "atomic",
      text: " ",
      entityRanges: [{ key }],
    })),
    entityMap: [
      { key: "0", value: { type: "MARKDOWN", data: { markdown: "```swift\nprint(1)\n```" } } },
      { key: "1", value: { type: "DIVIDER", data: {} } },
      { key: "2", value: { type: "TWEET", data: { tweetId: "123" } } },
      { key: "3", value: { type: "LINK", data: { url: "https://example.invalid" } } },
      { key: "4", value: { type: "IMAGE", data: {} } },
    ],
  },
  {
    blocks: [
      { type: "header-two", text: "Section" },
      { type: "unordered-list-item", text: "Item" },
      { type: "blockquote", text: "Quote" },
      { type: "atomic", entityRanges: [{ key: 99 }] },
    ],
  },
]
writeFileSync(
  new URL("../Tests/XClientTests/Fixtures/bird-0.8-tweets.json", import.meta.url),
  JSON.stringify(
    {
      reference: "Bird 0.8.0",
      mapping,
      rich: rich.map((input) => ({ input, expected: renderContentState(input) ?? null })),
    },
    null,
    2,
  ) + "\n",
)
const rendering = []
for (const mode of ["normal", "plain", "noEmoji"]) {
  const args = mode === "normal" ? [] : [mode === "plain" ? "--plain" : "--no-emoji"]
  const ctx = createCliContext(["node", "bird", ...args], { NO_COLOR: "1" })
  for (const fixture of mapping.filter((item) => item.expected)) {
    const lines = []
    const originalLog = console.log
    try {
      console.log = (value) => lines.push(String(value))
      ctx.printTweets([fixture.expected], { showSeparator: false })
      lines.push(formatStatsLine(fixture.expected, ctx.getOutput()))
    } finally {
      console.log = originalLog
    }
    rendering.push({ name: fixture.name, mode, tweet: fixture.expected, expected: lines.join("\n") })
  }
}
const program = createProgram(createCliContext(["node", "bird", "--plain"], { NO_COLOR: "1" }))
const globalOptions = program.options.map((option) => ({
  flags: option.flags,
  long: option.long,
  short: option.short,
  default: option.defaultValue,
}))
const commands = program.commands.map((command) => ({
  name: command.name(),
  aliases: command.aliases(),
  options: command.options.map((option) => ({
    flags: option.flags,
    long: option.long,
    short: option.short,
    default: option.defaultValue,
  })),
  arguments: command.registeredArguments.map((arg) => ({
    name: arg.name(),
    required: arg.required,
    variadic: arg.variadic,
  })),
}))
const cliDirectory = new URL("../Tests/AviaryCLITests/Fixtures/", import.meta.url)
mkdirSync(cliDirectory, { recursive: true })
writeFileSync(
  new URL("bird-0.8-cli.json", cliDirectory),
  JSON.stringify({ reference: "Bird 0.8.0", globalOptions, commands, rendering }, null, 2) + "\n",
)
console.log(`Generated ${mapping.length} tweet and ${rich.length} article fixtures from Bird (read-only).`)
console.log(`Generated ${commands.length} command contracts and ${rendering.length} text-output fixtures.`)
