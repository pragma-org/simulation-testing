{-# LANGUAGE BangPatterns #-}

module Moskstraumen.Debugger.SequenceDiagram (module Moskstraumen.Debugger.SequenceDiagram) where

import qualified Data.Text as Text

import Moskstraumen.Prelude

------------------------------------------------------------------------

type Name = Text

hLine :: Text
hLine = "─"

vLine :: Text
vLine = "│"

mkBoxLines :: Bool -> Bool -> [(Int, Name)] -> [Text]
mkBoxLines isTop dotted allBoxes =
  let (x, y, z) = go allBoxes
  in  if isTop then [x, y, z, extraLine] else [extraLine, x, y, z]
  where
    emptySpace i = (Text.replicate i " ", Text.replicate i " ", Text.replicate i " ")
    extraLine = mygo allBoxes
      where
        mygo [] = mempty
        mygo ((pre, name) : xs) =
          Text.replicate (pre + 2 + Text.length name `div` 2) " "
            <> if dotted
              then "⋮"
              else
                vLine
                  <> Text.replicate (Text.length name `div` 2 + 2) " "
                  <> mygo xs
    go :: [(Int, Name)] -> (Text, Text, Text)
    go [] = mempty
    go ((pre, name) : xs) =
      emptySpace pre
        <> ( "╭"
              <> Text.replicate (Text.length name `div` 2 + 1) hLine
              <> (if isTop then hLine else "┴")
              <> Text.replicate (Text.length name `div` 2 + 1) hLine
              <> "╮"
           , (vLine <> " ")
              <> name
              <> (if Text.length name `mod` 2 == 0 then " " else "")
              <> (" " <> vLine)
           , "╰"
              <> Text.replicate (Text.length name `div` 2 + 1) hLine
              <> (if isTop then "┬" else hLine)
              <> Text.replicate (Text.length name `div` 2 + 1) hLine
              <> "╯"
           )
        <> go xs

mkArrow :: [(Int, Name)] -> Int -> Int -> Message -> [Text]
mkArrow allBoxes from to (Message msg msgLen) = let (x, y) = go 0 allBoxes in [x, y]
  where
    go _ [] = mempty
    go c ((pre, name) : xs) =
      ( topLine
          <> Text.replicate (Text.length name `div` 2 + 1) " "
          <> Text.concat [" ", vLine, " "]
          <> Text.replicate (Text.length name `div` 2 + 1) " "
      , Text.replicate (pre + Text.length name `div` 2 + 1) before
          <> middle
          <> Text.replicate (Text.length name `div` 2 + 1) after
      )
        <> go (succ c) xs
      where
        topLine
          | c == succ from && from < to = msg <> Text.replicate (pre - msgLen) " "
          | c == from && from > to = Text.replicate (pre - msgLen) " " <> msg
          | otherwise = Text.replicate pre " "
        lower = min from to
        higher = max from to
        middle
          | c == from && from < to = " ├" <> hLine
          | c == from && from > to = hLine <> "┤ "
          | c == to && from < to = "▶" <> vLine <> " "
          | c == to && from > to = " " <> vLine <> "◀"
          | otherwise =
              Text.concat
                [ active c
                , if isActive c then "┼" else vLine
                , active (succ c)
                ]
        isActive x = lower < x && x <= higher
        active x
          | isActive x = hLine
          | otherwise = " "
        before = active c
        after = active (succ c)

data Message = Message Text Int

simpleMessage :: Text -> Message
simpleMessage x = Message (" " <> x <> " ") (2 + Text.length x)

markedMessage :: Text -> Message
markedMessage x = Message ("\x001b[93m[" <> x <> "]\x001b[0m") (2 + Text.length x)

data Arrow msg = Arrow
  { aFrom :: Name
  , aTo :: Name
  , aAt :: Int
  , aMessage :: msg
  }
  deriving stock (Show)

generate :: [Arrow Text] -> Int -> Int -> Text
generate originalArrs current height =
  Text.unlines
    $ mkBoxLines True (dropBeginning > 0) names
    <> concat
      [ mkArrow names fromIndex toIndex msg
      | arr <- take howManyElements $ drop dropBeginning arrsMsg
      , let fromIndex = index (aFrom arr) names
            toIndex = index (aTo arr) names
            msg = aMessage arr
      ]
    <> mkBoxLines
      False
      (howManyElements < length originalArrs - dropBeginning)
      names
  where
    indexOfCurrent = mygo 0 originalArrs -- TODO this is wrong
      where
        mygo n [] =
          error
            ( "INTERNAL ERROR! can't find current index: "
                <> show (n, current, originalArrs)
            )
        mygo n (arr : arrs)
          | aAt arr == current = n
          | otherwise = mygo (succ n) arrs

    howManyElements = (height - 2 * 4) `div` 2 -- number of arrows we should display
    atLeastHowManyAfter = min 5 howManyElements

    dropBeginning =
      max
        ( min (length originalArrs) (indexOfCurrent + atLeastHowManyAfter)
            - howManyElements
        )
        0

    arrsMsg =
      fmap
        ( \arr ->
            if aAt arr == current
              then arr {aMessage = markedMessage (aMessage arr)}
              else arr {aMessage = simpleMessage (aMessage arr)}
        )
        originalArrs
    index _ [] = error "INTERNAL ERROR! can't find name"
    index k ((_, x) : xs)
      | k == x = 0
      | otherwise = 1 + index k xs
    names = go (zip (repeat 0) (collectNames [] arrsMsg)) arrsMsg

    ensureSlack :: Int -> Int -> [(Int, Name)] -> [(Int, Name)]
    ensureSlack slack 0 ((p, x) : xs) = (max slack p, x) : xs
    ensureSlack slack n (x : xs) = x : ensureSlack slack (pred n) xs
    ensureSlack _slack _n [] = error "INTERNAL ERROR! can't ensure slack"

    add :: Name -> [Name] -> [Name]
    add x [] = [x]
    add x as@(k : xs)
      | k == x = as
      | otherwise = k : add x xs
    collectNames ns [] = ns
    collectNames ns (arr : arrs) = collectNames (add (aTo arr) $ add (aFrom arr) ns) arrs

    go :: [(Int, Name)] -> [Arrow Message] -> [(Int, Name)]
    go ns [] = ns
    go ns (arr : arrs) = go (ensureSlack msgLen pos ns) arrs
      where
        Message _ msgLen = aMessage arr
        fromIndex = index (aFrom arr) ns
        toIndex = index (aTo arr) ns

        pos
          | fromIndex < toIndex = succ fromIndex
          | otherwise = fromIndex

example :: Int -> Text
example = generate arrs 1000
  where
    arrs =
      [ Arrow "Client" "Dumblog" 0 "Append"
      , Arrow "Dumblog" "Backup" 1 "Write"
      , Arrow "Backup" "Dumblog" 2 "Ack"
      , Arrow "Dumblog" "Client" 3 "Ok"
      , Arrow "Backup" "Client" 4 "Test"
      ]
