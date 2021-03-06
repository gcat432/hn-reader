import algorithm
import asyncdispatch
import asyncfutures
import browsers
import httpclient
import json
import math
import options
import sequtils
import strformat
import sugar
import times

type
  Story* = object
    id*: int64
    author*: string
    time*: int
    comments*: int
    score*: int
    title*: string
    url*: string
    dead*: bool

type
  Get* = enum
    ## Defines the end-point within the HN API for a list of story IDs.
    topstories, newstories, beststories, showstories, askstories

  Sort* = enum
    ## How a sequence of stories should be sorted.
    byrank, bytime, byscore, bycomments

const api = "https://hacker-news.firebaseio.com/v0"

proc itemUrl(id: int64): string =
  ## Get the HN URL for a the comments page of a story.
  fmt"https://news.ycombinator.com/item?id={id}"

proc age*(story: Story): float64 =
  ## Age of a story in hours.
  (now().utc.toTime().toUnix() - story.time).float64 / 3600

proc rank*(story: Story): float64 =
  ## Page ranking of a story.
  let
    score = (story.score.float64 - 1).pow(0.8)
    age = (story.age + 2).pow(1.8)
    factor = if story.url == "": 0.4 else: 1.0

  score * factor / age

proc open*(story: Story, comments: bool=false) =
  ## Open a story's URL or item URL page in the browser.
  let url =
    if comments or story.url == "":
      story.id.itemUrl
    else:
      story.url

  # launch the external browser
  openDefaultBrowser(url)

proc postStatus*(story: Story): string =
  ## A string about who posted, when, popularity, etc.
  let
    age = story.age()
    ago =
      if age < 1: "less than an hour"
      elif age < 2: "an hour"
      elif age < 24: fmt"{age.int} hours"
      elif age < 168: fmt"{(age / 24).int} days"
      elif age < 672: fmt"{(age / 168).int} weeks"
      elif age < 8760: fmt"{(age / 672).int} months"
      else: fmt"{(age / 8760).int} years"

  fmt"posted by {story.author} {ago} ago ({story.score} votes) - {story.comments} comments"

proc hnGet*(path: string): Future[JsonNode] {.async.} =
  ## Downloads and parses a JSON response from the HN API.
  let resp = newAsyncHttpClient().getContent(fmt"{api}/{path}.json")
  return parseJson(await resp)

proc hnGetStoryIds*(get: Get): Future[seq[int64]] {.async.} =
  ## Downloads a list of story IDs from HN.
  return to(await hnGet($get), seq[int64])

proc hnGetStory*(id: int64): Future[Option[Story]] {.async.} =
  ## Downloads and parses a single Story from HN.
  let json = await hnGet(fmt"item/{id}")

  # check to make sure the story downloaded
  if json.kind != JNull:
    let
      id = json{"id"}.getInt()
      story = Story(
        id: id,
        author: json{"by"}.getStr(),
        title: json{"title"}.getStr(),
        url: json{"url"}.getStr(id.itemUrl),
        score: json{"score"}.getInt(),
        time: json{"time"}.getInt(),
        comments: json{"descendants"}.getInt(),
        dead: json{"dead"}.getBool(),
      )

    result = some(story)

proc hnGetStories*(get: Get, progress: proc(n, m: int) {.gcsafe.}=nil): Future[seq[Story]] {.async.} =
  ## Downloads a list of stories in parallel given their IDs.
  var futures = newSeq[Future[Option[Story]]]()
  var n = 0

  # download each story
  for id in await hnGetStoryIds(get):
    var f = hnGetStory(id)

    # when done, update the progress
    f.callback = proc() =
      n += 1

      if not progress.isNil:
        progress(n, futures.high + 1)

    # create a list of all the futures
    futures.add(f)

  # send an initial progress update
  if not progress.isNil:
    progress(0, futures.high + 1)

  # wait for all the stories to finish
  var stories = await all(futures)

  # remove any dead stories (none = dead by default)
  stories.keepIf(proc(s: Option[Story]): bool = not s.map((s) => s.dead).get(true))

  # pull all the remaining stories out of the option
  return stories.map(proc(s: Option[Story]): Story = s.get())

proc sort*(stories: var openArray[Story], by: Sort=byrank) =
  ## Sort using a sort compare enumeration.
  case by
  of byrank: sort(stories, (a, b) => cmp(b.rank(), a.rank()))
  of bytime: sort(stories, (a, b) => cmp(b.time, a.time))
  of byscore: sort(stories, (a, b) => cmp(b.score, a.score))
  of bycomments: sort(stories, (a, b) => cmp(b.comments, a.comments))
