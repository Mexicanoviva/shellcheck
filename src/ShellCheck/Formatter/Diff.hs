{-
    Copyright 2019 Vidar 'koala_man' Holen

    This file is part of ShellCheck.
    https://www.shellcheck.net

    ShellCheck is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    ShellCheck is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
-}
{-# LANGUAGE TemplateHaskell #-}
module ShellCheck.Formatter.Diff (format, ShellCheck.Formatter.Diff.runTests) where

import ShellCheck.Interface
import ShellCheck.Fixer
import ShellCheck.Formatter.Format

import Control.Monad
import Data.Algorithm.Diff
import Data.Array
import Data.IORef
import Data.List
import qualified Data.Monoid as Monoid
import Data.Maybe
import qualified Data.Map as M
import GHC.Exts (sortWith)
import System.IO
import System.FilePath

import Test.QuickCheck

import Debug.Trace
ltt x = trace (show x) x

format :: FormatterOptions -> IO Formatter
format options = do
    didOutput <- newIORef False
    shouldColor <- shouldOutputColor (foColorOption options)
    let color = if shouldColor then colorize else nocolor
    return Formatter {
        header = return (),
        footer = checkFooter didOutput color,
        onFailure = reportFailure color,
        onResult  = reportResult didOutput color
    }


contextSize = 3
red = 31
green = 32
yellow = 33
cyan = 36
bold = 1

nocolor n = id
colorize n s = (ansi n) ++ s ++ (ansi 0)
ansi n = "\x1B[" ++ show n ++ "m"

printErr :: ColorFunc -> String -> IO ()
printErr color = hPutStrLn stderr . color bold . color red
reportFailure color file msg = printErr color $ file ++ ": " ++ msg

checkFooter didOutput color = do
    output <- readIORef didOutput
    unless output $
            printErr color "Issues were detected, but none were auto-fixable. Use another format to see them."

type ColorFunc = (Int -> String -> String)
data DiffDoc a = DiffDoc String [DiffRegion a]
data DiffRegion a = DiffRegion (Int, Int) (Int, Int) [Diff a]

reportResult :: (IORef Bool) -> ColorFunc -> CheckResult -> SystemInterface IO -> IO ()
reportResult didOutput color result sys = do
    let comments = crComments result
    let suggestedFixes = mapMaybe pcFix comments
    let fixmap = buildFixMap suggestedFixes
    mapM_ output $ M.toList fixmap
  where
    output (name, fix) = do
        file <- (siReadFile sys) name
        case file of
            Right contents -> do
                putStrLn $ formatDoc color $ makeDiff name contents fix
                writeIORef didOutput True
            Left msg -> reportFailure color name msg

makeDiff :: String -> String -> Fix -> DiffDoc String
makeDiff name contents fix =
    DiffDoc name $ findRegions . groupDiff $ computeDiff contents fix

computeDiff :: String -> Fix -> [Diff String]
computeDiff contents fix =
    let old = lines contents
        array = listArray (1, fromIntegral $ (length old)) old
        new = applyFix fix array
    in getDiff old new

-- Group changes into hunks
groupDiff :: [Diff a] -> [(Bool, [Diff a])]
groupDiff = filter (\(_, l) -> not (null l)) . hunt []
  where
    -- Churn through 'Both's until we find a difference
    hunt current [] = [(False, reverse current)]
    hunt current (x@Both {}:rest) = hunt (x:current) rest
    hunt current list =
        let (context, previous) = splitAt contextSize current
        in (False, reverse previous) : gather context 0 list

    -- Pick out differences until we find a run of Both's
    gather current n [] =
        let (extras, patch) = splitAt (max 0 $ n - contextSize) current
        in [(True, reverse patch), (False, reverse extras)]

    gather current n list@(Both {}:_) | n == contextSize*2 =
        let (context, previous) = splitAt contextSize current
        in (True, reverse previous) : hunt context list

    gather current n (x@Both {}:rest) = gather (x:current) (n+1) rest
    gather current n (x:rest) = gather (x:current) 0 rest

-- Get line numbers for hunks
findRegions :: [(Bool, [Diff String])] -> [DiffRegion String]
findRegions = find' 1 1
  where
    find' _ _ [] = []
    find' left right ((output, run):rest) =
        let (dl, dr) = countDelta run
            remainder = find' (left+dl) (right+dr) rest
        in
            if output
            then DiffRegion (left, dl) (right, dr) run : remainder
            else remainder

-- Get left/right line counts for a hunk
countDelta :: [Diff a] -> (Int, Int)
countDelta = count' 0 0
  where
    count' left right [] = (left, right)
    count' left right (x:rest) =
        case x of
            Both {} -> count' (left+1) (right+1) rest
            First {} -> count' (left+1) right rest
            Second {} -> count' left (right+1) rest

formatRegion :: ColorFunc -> DiffRegion String -> String
formatRegion color (DiffRegion left right diffs) =
    let header = color cyan ("@@ -" ++ (tup left) ++ " +" ++ (tup right) ++" @@")
    in
        unlines $ header : map format diffs
  where
    tup (a,b) = (show a) ++ "," ++ (show b)
    format (Both x _) = ' ':x
    format (First x) = color red $ '-':x
    format (Second x) = color green $ '+':x

formatDoc color (DiffDoc name regions) =
          (color bold $ "--- " ++ ("a" </> name)) ++ "\n" ++
          (color bold $ "+++ " ++ ("b" </> name)) ++ "\n" ++
          concatMap (formatRegion color) regions

-- Create a Map from filename to Fix
buildFixMap :: [Fix] -> M.Map String Fix
buildFixMap fixes = perFile
  where
    splitFixes = concatMap splitFixByFile fixes
    perFile = groupByMap (posFile . repStartPos . head . fixReplacements) splitFixes

-- There are currently no multi-file fixes, but let's handle it anyways
splitFixByFile :: Fix -> [Fix]
splitFixByFile fix = map makeFix $ groupBy sameFile (fixReplacements fix)
  where
    sameFile rep1 rep2 = (posFile $ repStartPos rep1) == (posFile $ repStartPos rep2)
    makeFix reps = newFix { fixReplacements = reps }

groupByMap :: (Ord k, Monoid v) => (v -> k) -> [v] -> M.Map k v
groupByMap f = M.fromListWith Monoid.mappend . map (\x -> (f x, x))

-- For building unit tests
b n = Both n n
l = First
r = Second

prop_identifiesProperContext = groupDiff [b 1, b 2, b 3, b 4, l 5, b 6, b 7, b 8, b 9] ==
    [(False, [b 1]), -- Omitted
    (True, [b 2, b 3, b 4, l 5, b 6, b 7, b 8]), -- A change with three lines of context
    (False, [b 9])]  -- Omitted

prop_includesContextFromStartIfNecessary = groupDiff [b 4, l 5, b 6, b 7, b 8, b 9] ==
    [ -- Nothing omitted
    (True, [b 4, l 5, b 6, b 7, b 8]), -- A change with three lines of context
    (False, [b 9])]  -- Omitted

prop_includesContextUntilEndIfNecessary = groupDiff [b 4, l 5] ==
    [ -- Nothing omitted
        (True, [b 4, l 5])
    ] -- Nothing Omitted

prop_splitsIntoMultipleHunks = groupDiff [l 1, b 1, b 2, b 3, b 4, b 5, b 6, b 7, r 8] ==
    [ -- Nothing omitted
        (True, [l 1, b 1, b 2, b 3]),
        (False, [b 4]),
        (True, [b 5, b 6, b 7, r 8])
    ] -- Nothing Omitted

prop_splitsIntoMultipleHunksUnlessTouching = groupDiff [l 1, b 1, b 2, b 3, b 4, b 5, b 6, r 7] ==
    [
        (True, [l 1, b 1, b 2, b 3, b 4, b 5, b 6, r 7])
    ]

prop_countDeltasWorks = countDelta [b 1, l 2, r 3, r 4, b 5] == (3,4)
prop_countDeltasWorks2 = countDelta [] == (0,0)

return []
runTests = $quickCheckAll
