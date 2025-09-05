module Moskstraumen.Fault (module Moskstraumen.Fault) where

import qualified Data.Text as Text

import Moskstraumen.Generate
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Time

------------------------------------------------------------------------

-- start snippet Fault
data Fault = PartitionFault Partition
  deriving stock (Show, Read, Eq, Ord)

data Partition
  = None
  | Split SplitKind [NodeId]
  deriving stock (Show, Read, Eq, Ord)

data SplitKind = Single | Majority | Minority | MinorityThird
  deriving stock (Show, Read, Eq, Ord)

affected :: NodeId -> NodeId -> Partition -> Bool
affected src _dest _partition | isClientNodeId src = False
affected src dest (Split _kind nodes) =
  src
    `elem` nodes
    && dest
    `notElem` nodes
    || src
    `notElem` nodes
    && dest
    `elem` nodes
affected _src _dest None = False

-- end snippet

------------------------------------------------------------------------

majority :: Int -> Int
majority n = (n `div` 2) + 1

unit_majority :: Bool
unit_majority =
  map majority [0 .. 19]
    == [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10]

minorityThird :: Int -> Int
minorityThird n = max 0 (n - 1) `div` 3

unit_minorityThird :: Bool
unit_minorityThird =
  map minorityThird [0 .. 19]
    == [0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6]

------------------------------------------------------------------------

generatePartitions ::
  [NodeId] -> (Time, Time) -> Int -> Gen [(Time, Fault)]
generatePartitions nodes (start, end) durationMicros = go start []
  where
    go time acc
      | time' >= end = return (reverse acc)
      | otherwise = do
          partition <- generatePartition nodes
          go
            time'
            ((time', PartitionFault None) : (time, PartitionFault partition) : acc)
      where
        time' = addTimeMicros durationMicros time

generatePartition :: [NodeId] -> Gen Partition
generatePartition nodes =
  frequency
    [ (1, Split Single <$> subset 1 nodes)
    , (1, Split Majority <$> subset (majority (length nodes)) nodes)
    , (1, Split Minority <$> subset (majority (length nodes) - 1) nodes)
    , (1, Split MinorityThird <$> subset (minorityThird (length nodes)) nodes)
    ]
