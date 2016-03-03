{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE PolyKinds #-}
module Main where

import Control.Lens ((^.), (.~), (?~), (&), (%~), (^?), _Just)
import Control.Lens.At (ix)
import Control.Lens.TH (makeLenses)
import Control.Monad (when)
import Data.Char (chr)
import qualified Data.JSString as JS
import Data.JSString.Text (textToJSString, textFromJSString)
import Data.List (findIndex, groupBy, null, splitAt)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromJust, fromMaybe, maybe)
import Data.Monoid ((<>))
import Data.Patch (Patch, Edit(..), toList, fromList, apply, diff)
import qualified Data.Patch as Patch
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Vector (Vector, (!))
import qualified Data.Vector as Vector
import Servant.API ()
import Servant.Isomaniac (HasIsomaniac, MUV(..), ReqAction(..), isomaniac, muv, runIdent)
import Servant.Common.BaseUrl
import Servant.Common.Req (Req(..))
import Language.Haskell.HSX.QQ (hsx)
import Web.ISO.HSX
import Web.ISO.Types hiding (Context2D(Font))

-- type Document = Vector Char -- [Edit Char]
type Index = Int
type FontMetrics = Map RichChar (Double, Double)

data FontStyle
  = Normal
  | Bold
  | Italic
  deriving (Eq, Ord, Show)

data Font = Font
 { _fontStyle :: FontStyle
 , _fontSize  :: Double
 }
 deriving (Eq, Ord, Show)

data RichChar = RichChar
  { _font :: Font
  , _char :: Char
  }
  deriving (Eq, Ord, Show)
makeLenses ''RichChar


-- | a block of non-breaking Text
--
-- We have a list of [(Font,Text)]. This allows us to do things like
-- have the font style change in the middle of a word with out
-- introducing the possibility that the layout engine will insert a
-- line-break in the middle of the world.
data RichText = RichText
  { _text :: [(Font, Text)]
  }
  deriving (Eq, Show)
makeLenses ''RichText

richTextLength :: RichText -> Int
richTextLength (RichText txts) = sum (map (Text.length . snd) txts)

richCharsToRichText :: [RichChar] -> RichText
richCharsToRichText []    = RichText []
richCharsToRichText chars =
  RichText $ map flatten $ groupBy (\(RichChar f _) (RichChar f' _) -> f == f') chars
  where
    flatten :: [RichChar] -> (Font, Text)
    flatten chars = ((head chars) ^. font, Text.pack (map _char chars))

richTextToRichChars :: RichText -> [RichChar]
richTextToRichChars (RichText texts) =
  concatMap (\(font, txt) -> [ RichChar font c | c <- Text.unpack txt ]) texts

data Box c a = Box
  { _boxWidth     :: Double
  , _boxHeight    :: Double
  , _boxContent   :: a
  }
  deriving (Eq, Show)
makeLenses ''Box

data Image = Image
  { _imageUrl :: Text
  , _imageWidth :: Double
  , _imageHeight :: Double
  }
  deriving (Eq, Show)
makeLenses ''Image

data Atom
  = RC RichChar
  | RT RichText
  | Img Image
    deriving (Eq, Show)

isRichChar :: Atom -> Bool
isRichChar (RC {}) = True
isRichChar _             = False

unRichChar :: Atom -> RichChar
unRichChar (RC rc) = rc

atomLength :: Atom -> Int
atomLength (RC {})  = 1
atomLength (RT (RichText txts)) = sum (map (Text.length . snd) txts)
atomLength (Img {})       = 1


-- type TextBox  = Box Text Text
-- type ImageBox = Box Image Image

type AtomBox  = Box Singleton Atom

data Direction
  = Horizontal
  | Vertical
  | Singleton
    deriving (Eq, Show)

type HBox a = Box Horizontal a
type VBox a = Box Vertical a

{-

A document is formed by apply a list of Patch to mempty.

Patches have some restrictions. Edits in a patch can not depend on each other.

  "Patch resolution happens in zero time. Each edit in a particular
   patch is independent of any other edit. There is no telescopic
   dependency. E.g a patch P.fromList [a,b,c], if I remove the edit a,
   the edits b and c will work correctly unchanged, because they don't
   depend on a."

This means that the same patch can not add and then remove a character.

We wish to preserve the history of edits. We can do this by having
Patches that reflect what actually happened rather than consolidating
them.

As a basic rule we close the current patch and start a new one anytime we:

 1. insert after a delete
 2. delete after an insert
 3. change the caret position via the mouse/keyboard arrows (aka, with out inserting a character)

A deletion is always performed from the beginning of the text. Which in this case is the begining of the document.

-}

data EditState
  = Inserting
  | Deleting
  | MovingCaret
    deriving (Show, Eq)

data SelectionData = SelectionData
  { _selection       :: Selection
  , _selectionString :: String
  , _rangeCount      :: Int
  }
makeLenses ''SelectionData

-- could have a cache version of the Document with all the edits applied, then new edits would just mod that document
data Model = Model
  { _document    :: Vector Atom -- ^ all of the patches applied but not the _currentEdit
  , _patches     :: [Patch Atom]
  , _currentEdit :: [Edit Atom]
  , _editState   :: EditState
  , _index       :: Index -- ^ current index for patch edit operations
  , _caret       :: Index -- ^ position of caret
  , _fontMetrics :: FontMetrics
  , _currentFont :: Font
  , _measureElem :: Maybe JSElement
  , _debugMsg    :: Maybe Text
  , _mousePos    :: Maybe (Double, Double)
  , _editorPos   :: Maybe DOMClientRect
  , _targetPos   :: Maybe DOMClientRect
  , _layout      :: VBox [HBox [AtomBox]]
  , _maxWidth    :: Double
  , _selectionData :: Maybe SelectionData
  }
makeLenses ''Model

data Action
    = KeyPressed Char
    | KeyDowned Int
    | UpdateMetrics
    | GetMeasureElement
    | MouseClick MouseEventObject
    | CopyA ClipboardEventObject
    | PasteA JS.JSString
    | AddImage
    deriving Show

data EditAction
  = InsertAtom Atom
  | DeleteAtom
  | MoveCaret Index
    deriving Show
{-
calcSizes :: [[TextBox]] -> VBox [HBox [TextBox]]
calcSizes [] = Box 0 0 []
calcSizes (line:lines) =
  mkBox (mkBox line : calcSizes lines)
  where
--    mkBox :: forall c. [TextBox] -> Box c [TextBox]
    mkBox :: [a] -> Box c [a]
    mkBox [] = Box 0 0 []
    mkBox boxes =
      Box { _boxWidth   = sum (map _boxWidth boxes)
          , _boxHeight  = maximum (map _boxHeight boxes)
          , _boxContent = boxes
          }
-}

calcSizes :: [[AtomBox]] -> VBox [HBox [AtomBox]]
calcSizes [] = Box 0 0 []
calcSizes lines =
  mkHBox (map mkHBox lines)
--  mkVBox [] -- (mkHBox line : calcSizes lines)
  where
--    mkVBox [] = Box 0 0 []
--    mkHBox [] = Box 0 0 []
    mkHBox boxes =
      Box { _boxWidth   = sum (map _boxWidth boxes)
          , _boxHeight  = maximum (map _boxHeight boxes)
          , _boxContent = boxes
          }

-- | convert a 'Text' to a 'Box'.
--
-- Note that the Text will be 'unbreakable'. If you want to be able to
-- break on whitespace, first use 'textToWords'.
textToBox :: FontMetrics -> RichText -> AtomBox
textToBox fm input
  | null (input ^. text) = Box { _boxWidth  = 0
                               , _boxHeight    = 0
                               , _boxContent   = RT input
                               }
  | otherwise =
      Box { _boxWidth     = foldr (\(f,txt) w' -> Text.foldr (\c w -> w + getWidth fm (RichChar f c)) w' txt) 0 (input ^. text)
          , _boxHeight    = maximum (map (getHeight fm) [ RichChar f (Text.head txt) | (f, txt) <- input ^. text ])
          , _boxContent   = RT input
          }
  where
    getWidth, getHeight :: FontMetrics -> RichChar -> Double
    getWidth  fm c = maybe 0 fst (Map.lookup c fm)
    getHeight fm c = maybe 0 snd (Map.lookup c fm)
{-
-- | similar to words except whitespace is preserved at the end of a word
textToWords :: Text -> [Text]
textToWords txt
  | Text.null txt = []
  | otherwise =
      let whiteIndex   = fromMaybe 0 $ findIndex (\c -> c ==' ') txt
          charIndex    = fromMaybe 0 $ findIndex (\c -> c /= ' ') (Text.drop whiteIndex txt)
      in case whiteIndex + charIndex of
          0 -> [txt]
          _ -> let (word, rest) = Text.splitAt (whiteIndex + charIndex) txt
               in (word : textToWords rest)
-}

-- | similar to words except whitespace is preserved at the end of a word
richCharsToWords :: [RichChar] -> [[RichChar]]
richCharsToWords [] = []
richCharsToWords txt =
      let whiteIndex   = fromMaybe 0 $ findIndex (\rc -> (rc ^. char) ==' ') txt
          charIndex    = fromMaybe 0 $ findIndex (\rc -> (rc ^. char) /= ' ') (drop whiteIndex txt)
      in case whiteIndex + charIndex of
          0 -> [txt]
          _ -> let (word, rest) = splitAt (whiteIndex + charIndex) txt
               in (word : richCharsToWords rest)

-- | FIXME: possibly not tail recursive -- should probably use foldr or foldl'
layoutBoxes :: Double -> (Double, [Box c a]) -> [[Box c a]]
layoutBoxes maxWidth (currWidth, []) = []
layoutBoxes maxWidth (currWidth, (box:boxes))
  | currWidth + (box ^. boxWidth) <= maxWidth =
      case layoutBoxes maxWidth ((currWidth + (box ^. boxWidth)), boxes) of
       [] -> [[box]] -- this is the last box
       (line:lines) -> (box:line):lines
  -- if a box is longer than the maxWidth we will place it at the start of a line and let it overflow
  | (currWidth == 0) && (box ^. boxWidth > maxWidth) =
      [box] : layoutBoxes maxWidth (0, boxes)
  | otherwise =
      ([]:layoutBoxes maxWidth (0, box:boxes))
{-
textToLines :: FontMetrics -> Double -> Int -> Text -> VBox [HBox [AtomBox]]
textToLines fm maxWidth caret txt =
  let boxes = map (textToBox fm) (textToWords txt)
  in calcSizes $ layoutBoxes maxWidth (0, boxes)
-}
-- FIXME: should probably use a fold or something
boxify :: FontMetrics -> Vector Atom -> [AtomBox]
boxify fm v
  | Vector.null v = []
  | otherwise =
    case (Vector.head v) of
      RC {} ->
        case Vector.span isRichChar v of
          (richChars, rest) ->
            (map (textToBox fm) $ map richCharsToRichText $ richCharsToWords $ (Vector.toList (Vector.map unRichChar richChars))) ++ (boxify fm rest)
      atom@(Img img) ->
        (Box (img ^. imageWidth) (img ^. imageHeight) atom) : boxify fm (Vector.tail v)

atomsToLines :: FontMetrics -> Double -> Vector Atom -> VBox [HBox [AtomBox]]
atomsToLines fm maxWidth atoms =
  let boxes = boxify fm atoms -- map (textToBox fm) (textToWords txt)
  in calcSizes $ layoutBoxes maxWidth (0, boxes)

insertChar :: Atom -> Model -> Model
insertChar atom model =
  let newEdit =  (model ^. currentEdit) ++ [Insert (model ^. index) atom] -- (if c == '\r' then RichChar '\n' else RichChar c)]
  in
   model { _currentEdit = newEdit
--        , _index    = model ^. index
         , _caret       = succ (model ^. caret)
         , _layout      = atomsToLines (model ^. fontMetrics) (model ^. maxWidth) (apply (Patch.fromList newEdit) (model ^. document))
  --       , _layout      = textToLines (model ^. fontMetrics) (model ^. maxWidth) 2 $ Text.pack $ Vector.toList (apply (Patch.fromList newEdit) (model ^. document))
         }

-- in --  newDoc =   (model ^. document) ++ [Delete (model ^. index) ' '] -- FIXME: won't work correctly if converted to a replace
backspaceChar :: Model -> Model
backspaceChar model
 | (model ^. index) > 0 = -- FIXME: how do we prevent over deletion?
  let index'  = pred (model ^. index)
      c       = (model ^. document) ! index'
      newEdit = (model ^. currentEdit) ++ [Delete index' c]
  in
   model { _currentEdit = newEdit
         , _index       = pred (model ^. index)
         , _caret       = pred (model ^. caret)
         , _layout      = atomsToLines (model ^. fontMetrics) (model ^. maxWidth) (apply (Patch.fromList newEdit) (model ^. document))
         }
 | otherwise = model

handleAction :: EditAction -> Model -> Model
handleAction ea model
  | model ^. editState == Inserting =
      case ea of
       InsertAtom c -> insertChar c model
       DeleteAtom ->
         let newPatch   = Patch.fromList (model ^. currentEdit)
             newPatches = (model ^. patches) ++ [newPatch]
             newDoc     = apply newPatch (model ^. document)
             model'     = model { _document    = newDoc
                                , _patches     = newPatches
                                , _currentEdit = []
                                , _editState   = Deleting
                                , _index       = model ^. caret
                                }
         in handleAction DeleteAtom model'
       MoveCaret {} ->
         let newPatch   = Patch.fromList (model ^. currentEdit)
             newPatches = (model ^. patches) ++ [newPatch]
             newDoc     = apply newPatch (model ^. document)
             model'     = model { _document    = newDoc
                                , _patches     = newPatches
                                , _currentEdit = []
                                , _editState   = MovingCaret
                                }
         in handleAction ea model'

  | model ^. editState == Deleting =
      case ea of
       DeleteAtom -> backspaceChar model
       InsertAtom _ ->
         let newPatch   = Patch.fromList (model ^. currentEdit)
             newPatches = (model ^. patches) ++ [newPatch]
             newDoc     = apply newPatch (model ^. document)
             model'     = model { _document = newDoc
                                , _patches  = newPatches
                                , _currentEdit = []
                                , _editState   = Inserting
                                }
         in handleAction ea model'
       MoveCaret {} ->
         let newPatch   = Patch.fromList (model ^. currentEdit)
             newPatches = (model ^. patches) ++ [newPatch]
             newDoc     = apply newPatch (model ^. document)
             model'     = model { _document    = newDoc
                                , _patches     = newPatches
                                , _currentEdit = []
                                , _editState   = MovingCaret
                                }
         in handleAction ea model'

  | model ^. editState == MovingCaret =
      case ea of
       MoveCaret i ->
         model { _index = i
               , _caret = i
               }
       InsertAtom {} ->
         handleAction ea (model { _editState = Inserting })
       DeleteAtom {} ->
         handleAction ea (model { _editState = Deleting })

{-
relativeClickPos model =
  let mepos = model ^. editorPos in
   case mepos of
    Nothing -> Nothing
    (Just epos) ->
      case model ^. mousePos of
       Nothing -> Nothing
      (Just (mx, my)) -> Just (mx - (rectLeft epos), my - (rectTop epos))
-}

relativeClickPos model mx my =
   case model ^. editorPos of
    Nothing     -> Nothing
    (Just epos) -> Just (mx - (rectLeft epos), my - (rectTop epos))

lineAtY :: VBox [HBox a] -> Double -> Maybe Int
lineAtY vbox y = go (vbox ^. boxContent) y 0
  where
    go [] _ _ = Nothing
    go (hbox:hboxes) y n =
      if y < hbox ^. boxHeight
      then Just n
      else go hboxes (y - hbox ^. boxHeight) (succ n)

-- If we put Characters in boxes then we could perhaps generalize this
indexAtX :: FontMetrics -> HBox [AtomBox] -> Double -> Int
indexAtX fm hbox x = go (hbox ^. boxContent) x 0
  where
    indexAtX' :: [RichChar] -> Double -> Int -> Int
    indexAtX' [] x i = i
    indexAtX' (c:cs) x i =
      let cWidth =  fst $ fromJust $ Map.lookup c fm
      in if x < cWidth
         then i
         else indexAtX' cs (x - cWidth) (succ i)
    go :: [AtomBox] -> Double -> Int -> Int
    go [] x i = i
    go (box:boxes) x i =
      case box ^. boxContent of
        (RT txt)
         | x < (box ^. boxWidth) ->
            indexAtX' (richTextToRichChars txt) x i
         | otherwise -> go boxes (x - box ^. boxWidth) (i + richTextLength txt)
        (Img img)
         | x < (box ^. boxWidth) -> i
         | otherwise ->  go boxes (x - box ^. boxWidth) (i + 1)

indexAtPos :: FontMetrics -> VBox [HBox [AtomBox]] -> (Double, Double) -> Maybe Int
indexAtPos fm vbox (x,y) =
  case lineAtY vbox y of
   Nothing -> Nothing
   (Just i) -> Just $ (sumPrevious $ take i (vbox ^. boxContent)) + indexAtX fm ((vbox ^. boxContent)!!i) x
   where
--     sumPrevious :: VBox [HBox [TextBox]] -> Maybe Int
     sumPrevious vboxes = sum (map sumLine vboxes)
--     sumPrevious :: VBox [HBox [TextBox]] -> Maybe Int
     sumLine vbox = sum (map (\box -> atomLength (box ^. boxContent)) (vbox ^. boxContent))

-- | FIXME
getFontMetric :: JSElement -> RichChar -> IO (RichChar, (Double, Double))
getFontMetric measureElm rc@(RichChar _ c) =
  do setInnerHTML measureElm (JS.pack $ replicate 100 (if c == ' ' then '\160' else c))
     domRect <- getBoundingClientRect measureElm
     -- FIXME: width and height are not official properties of DOMClientRect
     let w = width domRect / 100
         h = height domRect
     pure (rc, (w, h))

getSelectionData :: IO (Maybe SelectionData)
getSelectionData =
  do w <- window
     sel <- getSelection w
--     js_alert =<< (selectionToString sel)
     c <- getRangeCount sel
     txt <- selectionToString sel
     pure $ Just $ SelectionData { _selection = sel
                                 , _selectionString = JS.unpack txt
                                 , _rangeCount = c
                                 }

{-
foreign import javascript unsafe "$1[\"clipboardData\"][\"getData\"](\"text/plain\")" getClipboardData ::
        ClipboardEventObject -> IO JS.JSString
-}

-- foreign import javascript unsafe "$1[\"focus\"]()" js_focus ::
--         JSElement -> IO ()

update' :: Action -> Model -> IO (Model, Maybe (ReqAction Action))
update' action model'' =
  do (Just doc)        <- currentDocument
     (Just editorElem) <- getElementById doc "editor"
     rect <- getBoundingClientRect editorElem
     mSelectionData <- getSelectionData
     let model = model'' { _editorPos = Just rect
                         , _selectionData = mSelectionData
                         }
     js_focus editorElem
     case action of
      AddImage       -> pure (handleAction (InsertAtom (Img (Image "http://i.imgur.com/YFtU4OV.png" 174 168))) model, Nothing)
      CopyA ceo      -> do cd <- clipboardData ceo
                           setDataTransferData cd "text/plain" "Boo-yeah!"
                           pure (model & debugMsg .~ Just "copy", Nothing)
      PasteA txt -> do -- txt <- getDataTransferData dt "text/plain"
--                       txt2 <- getClipboardData ceo
--                       js_alert txt2
                       pure (model & debugMsg .~ Just (textFromJSString txt), Nothing)
      KeyPressed c  -> pure (handleAction (InsertAtom (RC (RichChar (model ^. currentFont) c))) model, Nothing)
      KeyDowned c -- handle \r and \n ?
        | c == 8    -> pure (handleAction DeleteAtom model, Nothing)
        | c == 32   -> pure (handleAction (InsertAtom (RC (RichChar (model ^. currentFont) ' '))) model, Nothing) -- seems obsolete?
        | otherwise -> pure (model, Nothing)
      MouseClick e ->
        do elem <- target e
{-
         (Just doc) <- currentDocument
         (Just editorElem) <- getElementById doc "editor"
         rect <- getBoundingClientRect editorElem
-}

           targetRect <- getBoundingClientRect elem
           {-
           let highlightLine (Just n) lines = lines & ix n %~ lineHighlight .~ True
               highlightLine Nothing lines = lines
               (Just (x,y)) = relativeClickPos model (clientX e) (clientY e)
             -}
           let (Just (x,y)) = relativeClickPos model (clientX e) (clientY e)
               mIndex = indexAtPos (model ^. fontMetrics) (model ^. layout) (x,y)
               model' = model & mousePos ?~ (clientX e, clientY e)
                              & caret .~ (fromMaybe (model ^. caret) mIndex)
                              & targetPos ?~ targetRect
           case mIndex of
            (Just i) -> pure (handleAction (MoveCaret i) model', Nothing)
            Nothing  -> pure (model', Nothing)

--              & layout .~ highlightLine (lineAtY (model ^. layout) y) (map (\l -> l & lineHighlight .~ False) (model ^. layout))
--                       & layout .~ highlightLine (lineAtY (model ^. layout) y) (map (\l -> l & lineHighlight .~ False) (model ^. layout))
--                , Nothing)

      UpdateMetrics ->
        do case model ^. measureElem of
            Nothing -> do
              (Just document) <- currentDocument
              mme <- getElementById document "measureElement"
              case mme of
                Nothing -> pure (model { _debugMsg = Just "Could not find measureElement" }, Nothing)
                (Just me) ->
                  do let model' = model & measureElem .~ (Just me)
                     doMetrics model' me
            (Just me) -> doMetrics model me
        where
          doMetrics model me =
            do metrics <- mapM (getFontMetric me) [ RichChar (model ^. currentFont) c | c <- [' ' .. '~']]
               pure $ (model & fontMetrics .~ (Map.fromList metrics) {- & debugMsg .~ (Just $ Text.pack $ show metrics) -}, Nothing)

{-
textToBox :: FontMetrics -> Text -> TextBox
textToBox fm input
  | Text.null input = Box { _boxWidth     = 0
                          , _boxHeight    = 0
                          , _boxContent   = input
                          , _boxHighlight = False
                          }
  | otherwise =
      Box { _boxWidth     = Text.foldr (\c w -> w + getWidth fm c) 0 input
          , _boxHeight    = getHeight fm (Text.head input)
          , _boxContent   = input
          , _boxHighlight = False
          }
  where
    getWidth, getHeight :: FontMetrics -> Char -> Double
    getWidth  fm c = maybe 0 fst (Map.lookup c fm)
    getHeight fm c = maybe 0 snd (Map.lookup c fm)
-}
{-
-- foldl :: Foldable t => (b -> a -> b) -> b -> t a -> b
-- foldr :: Foldable t => (a -> b -> b) -> b -> t a -> b

-- | FIXME: possibly not tail recursive -- should probably use foldr or foldl'
layoutBoxes :: Double -> (Double, [Box a]) -> [[Box a]]
layoutBoxes maxWidth (currWidth, []) = []
layoutBoxes maxWidth (currWidth, (box:boxes))
  | currWidth + (box ^. boxWidth) <= maxWidth =
      case layoutBoxes maxWidth ((currWidth + (box ^. boxWidth)), boxes) of
       [] -> [[box]] -- this is the last box
       (line:lines) -> (box:line):lines
  -- if a box is longer than the maxWidth we will place it at the start of a line and let it overflow
  | (currWidth == 0) && (box ^. boxWidth > maxWidth) =
      [box] : layoutBoxes maxWidth (0, boxes)
  | otherwise =
      ([]:layoutBoxes maxWidth (0, box:boxes))


-}

renderAtomBox :: AtomBox -> [HTML Action]
-- renderTextBox box = CDATA True (box ^. boxContent)
renderAtomBox box =
  case box ^. boxContent of
    (RT (RichText txts)) -> map renderText txts
    (Img img)       -> [[hsx| <img src=(img ^. imageUrl) /> |]]
  where
    renderText :: (Font, Text) -> HTML Action
    renderText (_, txt) = [hsx| <span><% nbsp txt %></span>   |]
    nbsp = Text.replace " " (Text.singleton '\160')

renderAtomBoxes' :: HBox [AtomBox] -> HTML Action
renderAtomBoxes' box =
    [hsx| <div class=("line"::Text)><% concatMap renderAtomBox (box ^. boxContent)  %></div> |]
--  [hsx| <div class=(if line ^. lineHighlight then ("line highlight" :: Text) else "line")><% map renderTextBox (line ^. lineBoxes)  %></div> |]

renderAtomBoxes :: VBox [HBox [AtomBox]] -> HTML Action
renderAtomBoxes lines =
  [hsx| <div class="lines"><% map renderAtomBoxes' (lines ^. boxContent) %></div> |]

linesToHTML :: VBox [HBox [AtomBox]] -> HTML Action
linesToHTML lines = renderAtomBoxes lines
{-
textToHTML :: FontMetrics -> Double -> Int -> Text -> HTML Action
textToHTML fm maxWidth caret txt =
  let boxes = map (textToBox fm) (textToWords txt)
      boxes' = boxes & ix caret %~ boxHighlight .~ True
  in
   renderTextBoxes (layoutBoxes maxWidth (0, boxes'))
-}

renderDoc :: VBox [HBox [AtomBox]] -> HTML Action
renderDoc lines =
  [hsx|
    <div data-path="root">
     <% linesToHTML lines %>
--        <% textToHTML fm maxWidth 2 $ Text.pack $ Vector.toList (apply (Patch.fromList edits) mempty) %>
--      <% addP $ rlines $ Vector.toList (apply (Patch.fromList edits) mempty) %>
--      <% show $ map p $ rlines $ Vector.toList (apply (Patch.fromList edits) mempty) %>
    </div>
  |]
  where
    rlines :: String -> [String]
    rlines l =
      let (b, a) = break (\c -> c == '\n' || c == '\r') l
      in case a of
       [] -> [b]
       [c] -> b : [""]
       (_:cs) -> b : rlines cs


indexToPosAtom :: Int -> FontMetrics -> AtomBox -> Maybe Double
indexToPosAtom index fm box =
  case box ^. boxContent of
    (RT rt)
      | richTextLength rt < index -> Nothing
      | otherwise ->
        Just $ foldr sumWidth 0 (take index (richTextToRichChars rt))
    (Img img) -> Just (img ^. imageWidth) -- box ^. boxWidth
  where
    sumWidth c acc =
      case Map.lookup c fm of
        Just (w, _) -> acc + w
        Nothing -> acc

-- | given a character index, calculate its (left, top, height) coordinates in the editor
--
indexToPos :: Int
           -> Model
           -> Maybe (Double, Double, Double)
indexToPos i model = go (model ^. layout ^. boxContent) i (0,0,0)
  where
    -- go over the lines
    go [] _ _  = Nothing
    go (hbox:hboxes) i curPos =
      -- walk over thecurrent line
      case go' (hbox ^. boxContent) (hbox ^. boxHeight) i curPos of
       -- if the position is in current line, we are done
       (Right curPos') -> curPos'
       -- otherwise add the height of that line and start
       -- looking in the next line
       (Left (i', (x,y,height))) ->
         go hboxes i' (0, y + hbox ^. boxHeight, height)

    -- go over the atoms in a line
--     go' :: [AtomBox] -> Int -> Double -> Either (Int, Double) (Maybe Double)
    go' [] _ i curPos = Left (i, curPos)
    go' _ _ 0 curPos = Right (Just curPos)
    go' (box:boxes) lineHeight i (x,y,height) =
      -- if the index is greater than the length of the next atom
      if i > atomLength (box ^. boxContent)
         -- subtract length of next atom, add width, update height, check next atom
         then go' boxes lineHeight (i - atomLength (box ^. boxContent)) (x + box ^. boxWidth, y, box ^. boxHeight)
         -- if we found the atom we are looking for, look for x position within the atom
         else case indexToPosAtom i (model ^. fontMetrics) box of
               Nothing   -> Right Nothing
               (Just x') ->
                 let boxForHeight = box
                     {-
                       case boxes of
                         (box':_) -> box'
                         _        -> box
-}
                 in Right (Just (x + x', y + (lineHeight - (boxForHeight ^. boxHeight)), boxForHeight ^. boxHeight))

caretPos :: Model -> Maybe (Double, Double, Double) -> [KV Text Text]
caretPos model Nothing = []
caretPos model (Just (x, y, height)) =
  case model ^. editorPos of
   Nothing -> []
   (Just ep) -> ["style" := ("top: "        <> (Text.pack $ show y)      <>
                             "px; left: "   <> (Text.pack $ show x)      <>
                             "px; height: " <> (Text.pack $ show height) <>
                             "px;"
                             )
                ]
-- Event -> EIO Action
{-
<div> Click event
 <button onClick=Increment>+</button>
 <button onClick=Decrement>-</button>
</div>
-}
view' :: Model -> (HTML Action, [Canvas])
view' model =
  let keyDownEvent  = Event KeyDown  (\e -> when (keyCode e == 8 || keyCode e == 32) (preventDefault e) >> pure (KeyDowned (keyCode e)))
      keyPressEvent = Event KeyPress (\e -> pure (KeyPressed (chr (charCode e))))
      clickEvent    = Event Click    (\e -> pure (MouseClick e))
      copyEvent     = Event Copy     (\e -> do preventDefault e ; dt <- clipboardData e ; setDataTransferData dt "text/plain" "boo-yeah" ; pure (CopyA e))
      pasteEvent    = Event Paste    (\e -> do preventDefault e ; dt <- clipboardData e ; txt <- getDataTransferData dt "text/plain" ; pure (PasteA txt))
      addImage      = Event Click    (\e -> pure AddImage)
  in
         ([hsx|
           <div>
--            <p><% show (Patch.fromList (model ^. document)) %></p>

--            <p><% Vector.toList (apply (Patch.fromList (model ^. document)) mempty) %></p>
--            <p><% show $ textToWords $ Text.pack $ Vector.toList (apply (Patch.fromList (model ^. document)) mempty) %></p>
--            <p><% show $ layoutBoxes 300 (0, map (textToBox (model ^. fontMetrics)) $ textToWords $ Text.pack $ Vector.toList (apply (Patch.fromList (model ^. document)) mempty)) %></p>
--            <p><% show $ layoutBoxes 300 (0, map (textToBox (model ^. fontMetrics)) $ textToWords $ Text.pack $ Vector.toList (apply (Patch.fromList (model ^. document)) mempty)) %></p>
            <div style="float: right; width: 600px;">
             <h1>Debug</h1>
             <p>debugMsg: <% show (model ^. debugMsg) %></p>
             <p>mousePos: <% show (model ^. mousePos) %></p>
             <p>editorPos: <% let mpos = model ^. editorPos in
                     case mpos of
                      Nothing -> "(,)"
                      (Just pos) -> show (rectLeft pos, rectTop pos) %></p>
             <p><% let mepos = model ^. editorPos in
                     case mepos of
                      Nothing -> "(,)"
                      (Just epos) ->
                        case model ^. mousePos of
                             Nothing -> "(,)"
                             (Just (mx, my)) -> show (mx - (rectLeft epos), my - (rectTop epos)) %></p>
             <p>targetPos: <% let mpos = model ^. targetPos in
                     case mpos of
                      Nothing -> "(,)"
                      (Just pos) -> show (rectLeft pos, rectTop pos) %></p>
             <p>line heights: <% show (map _boxHeight (model ^. layout ^. boxContent)) %></p>
             <p>Document: <% show (model ^. document) %></p>
             <p>Patches: <% show (model  ^. patches) %></p>
             <p>Current Patch: <% show (model  ^. currentEdit) %></p>
             <p>Index: <% show (model ^. index) %></p>
             <p>Caret: <% show (model ^. caret) %></p>
             <% case model ^. selectionData of
                  Nothing -> <p>No Selection</p>
                  (Just selectionData) ->
                    <div>
                     <p>Selection: count=<% show $ selectionData ^. rangeCount %></p>
                     <p>Selection: len=<% show $ length $ selectionData ^. selectionString %></p>
                     <p>Selection: toString()=<% selectionData ^. selectionString %></p>
                    </div>
             %>
            </div>

            <h1>Editor</h1>
            <button [addImage]>Add Image</button>
            <div id="editor" tabindex="1" style="outline: 0; height: 600px; width: 300px; border: 1px solid black; box-shadow: 2px 2px 2px 1px rgba(0, 0, 0, 0.2);" autofocus="autofocus" [keyDownEvent, keyPressEvent, clickEvent, copyEvent] >
              <div id="caret" class="caret" (caretPos model (indexToPos (model ^. caret) model))></div>
              <% renderDoc (model ^. layout) %>
            </div>

           </div>
          |], [])

editorMUV :: MUV IO Model Action (ReqAction Action)
editorMUV =
  MUV { model  = Model { _document    = mempty
                       , _patches     = []
                       , _currentEdit = []
                       , _editState   = Inserting
                       , _index       = 0
                       , _caret       = 0
                       , _fontMetrics = Map.empty
                       , _currentFont = Font Normal 14.0
                       , _measureElem = Nothing
                       , _debugMsg    = Nothing
                       , _mousePos    = Nothing
                       , _editorPos   = Nothing
                       , _targetPos   = Nothing
                       , _layout      = Box 0 0 []
                       , _maxWidth    = 300
                       , _selectionData = Nothing
                       }
      , update = update'
      , view   = view'
      }

main :: IO ()
main =
  muv editorMUV id (Just UpdateMetrics)

-- main = pure ()

