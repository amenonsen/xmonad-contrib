{-# OPTIONS -fno-warn-orphans -fglasgow-exts #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  XMonadContrib.Tabbed
-- Copyright   :  (c) 2007 David Roundy, Andrea Rossato
-- License     :  BSD-style (see xmonad/LICENSE)
-- 
-- Maintainer  :  droundy@darcs.net, andrea.rossato@unibz.it
-- Stability   :  unstable
-- Portability :  unportable
--
-- A tabbed layout for the Xmonad Window Manager 
--
-----------------------------------------------------------------------------

module XMonadContrib.Tabbed ( 
                             -- * Usage:
                             -- $usage
                             tabbed
                            , TConf (..), defaultTConf
                            ) where

import Control.Monad.State ( gets )
import Control.Monad.Reader
import Data.Maybe
import Data.Bits
import Data.List

import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras

import XMonad
import Operations
import qualified StackSet as W

import XMonadContrib.NamedWindows
import XMonadContrib.XPrompt (fillDrawable, printString)

-- $usage
-- You can use this module with the following in your configuration file:
--
-- > import XMonadContrib.Tabbed
--
-- > defaultLayouts :: [(String, SomeLayout Window)]
-- > defaultLayouts = [SomeLayout tiled
-- >                  ,SomeLayout $ Mirror tiled
-- >                  -- Extension-provided layouts
-- >                  ,SomeLayout $ tabbed defaultTConf)
-- >                  , ... ]
--
-- You can also edit the default configuration options.
--
-- > myTabConfig = defaultTConf { inactiveBorderColor = "#FF0000"
-- >                            , activeTextColor = "#00FF00"}
--
-- and
--
-- > defaultLayouts = [ tabbed myTabConfig
-- >                  , ... ]

-- %import XMonadContrib.Tabbed
-- %layout , tabbed defaultTConf

tabbed :: TConf -> Tabbed a
tabbed t = Tabbed INothin t

data TConf = 
    TConf { activeColor         :: String
          , inactiveColor       :: String
          , activeBorderColor   :: String
          , inactiveTextColor   :: String
          , inactiveBorderColor :: String
          , activeTextColor     :: String
          , fontName            :: String
          , tabSize             :: Int
          } deriving (Show, Read)

defaultTConf :: TConf
defaultTConf = 
    TConf { activeColor         = "#999999"
          , inactiveColor       = "#666666"
          , activeBorderColor   = "#FFFFFF"
          , inactiveBorderColor = "#BBBBBB"
          , activeTextColor     = "#FFFFFF"
          , inactiveTextColor   = "#BFBFBF"
          , fontName            = "-misc-fixed-*-*-*-*-10-*-*-*-*-*-*-*"
          , tabSize             = 20
          }

data TabState = 
    TabState { tabsWindows :: [(Window,Window)]
             , scr         :: Rectangle
             , fontS       :: FontStruct -- FontSet
    } deriving ( Show , Read )

data Tabbed a = 
    Tabbed (InvisibleMaybe TabState) TConf
    deriving (Show, Read)

data InvisibleMaybe a = INothin | IJus a
instance Show (InvisibleMaybe a) where show _ = ""
instance Read (InvisibleMaybe a) where readsPrec _ s = [(INothin, s)]
whenIJus :: Monad m => InvisibleMaybe a -> (a -> m ()) -> m ()
whenIJus (IJus a) j = j a
whenIJus INothin _ = return ()

instance Layout Tabbed Window where
    doLayout (Tabbed mst conf) = doLay mst conf
    handleMessage              = handleMess

instance Read FontStruct where
    readsPrec _ _ = []

doLay :: InvisibleMaybe TabState -> TConf -> Rectangle -> W.Stack Window -> X ([(Window, Rectangle)], Maybe (Tabbed Window))
doLay mst _ sc (W.Stack w [] []) = do
  whenIJus mst $ \st -> destroyTabs (map fst $ tabsWindows st)
  return ([(w,sc)], Nothing)
doLay mst conf sc@(Rectangle _ _ wid _) s@(W.Stack w _ _) = do
  let ws = W.integrate s
      width = wid `div` fromIntegral (length ws)
      -- initialize state
  st <- case mst of
          INothin -> initState conf sc ws
          IJus ts -> if map snd (tabsWindows ts) == ws && scr ts == sc
                     then return ts
                     else do destroyTabs (map fst $ tabsWindows ts)
                             tws <- createTabs conf sc ws
                             return (ts {scr = sc, tabsWindows = zip tws ws})
  showTabs $ map fst $ tabsWindows st
  mapM_ (updateTab conf (fontS st) width) $ tabsWindows st
  return ([(w,shrink conf sc)], Just (Tabbed (IJus st) conf))

handleMess :: Tabbed Window -> SomeMessage -> X (Maybe (Tabbed Window))
handleMess (Tabbed (IJus st@(TabState {tabsWindows = tws}))  conf) m
    | Just e <- fromMessage m :: Maybe Event = handleEvent conf st e  >> return Nothing
    | Just Hide             == fromMessage m = hideTabs (map fst tws) >> return Nothing
    | Just ReleaseResources == fromMessage m = do d <- asks display
                                                  destroyTabs $ map fst tws
                                                  io $ freeFont d (fontS st)
                                                  return Nothing
handleMess _ _  = return Nothing

handleEvent :: TConf -> TabState -> Event -> X ()
-- button press
handleEvent conf (TabState    {tabsWindows = tws,   scr          = screen, fontS         = fs }) 
                 (ButtonEvent {ev_window   = thisw, ev_subwindow = thisbw, ev_event_type = t  })
    | t == buttonPress, tl <- map fst tws, thisw `elem` tl || thisbw `elem` tl  = do
  focus (fromJust $ lookup thisw tws)
  updateTab conf fs width (thisw, fromJust $ lookup thisw tws)
    where
      width = rect_width screen`div` fromIntegral (length tws)

handleEvent conf (TabState {tabsWindows = tws,   scr           = screen, fontS = fs }) 
                 (AnyEvent {ev_window   = thisw, ev_event_type = t                  })
-- expose
    | thisw `elem` (map fst tws) && t == expose         = do
  updateTab conf fs width (thisw, fromJust $ lookup thisw tws)
-- propertyNotify
    | thisw `elem` (map snd tws) && t == propertyNotify = do
  let tabwin = (fst $ fromJust $ find ((== thisw) . snd) tws, thisw)
  updateTab conf fs width tabwin
    where
      width = rect_width screen`div` fromIntegral (length tws)
handleEvent _ _ _ =  return ()

initState :: TConf -> Rectangle -> [Window] -> X TabState
initState conf sc ws = withDisplay $ \ d -> do
  fs <- io $ loadQueryFont d (fontName conf) `catch`
        \_-> loadQueryFont d "-misc-fixed-*-*-*-*-10-*-*-*-*-*-*-*"
  tws <- createTabs conf sc ws
  return $ TabState (zip tws ws) sc fs

createTabs :: TConf -> Rectangle -> [Window] -> X [Window]
createTabs _ _ [] = return []
createTabs c (Rectangle x y wh ht) owl@(ow:ows) = do
  let wid = wh `div` (fromIntegral $ length owl)
  d  <- asks display
  rt <- asks theRoot
  w  <- io $ createSimpleWindow d rt x y wid (fromIntegral $ tabSize c) 0 0 0
  io $ selectInput d w $ exposureMask .|. buttonPressMask
  io $ restackWindows d $ w : [ow]
  ws <- createTabs c (Rectangle (x + fromIntegral wid) y (wh - wid) ht) ows
  return (w:ws)

updateTab :: TConf -> FontStruct -> Dimension -> (Window,Window) -> X ()
updateTab c fs wh (tabw,ow) = do
  xc <- ask
  nw <- getName ow
  let ht                   = fromIntegral $ tabSize c :: Dimension
      d                    = display xc
      focusColor win ic ac = (maybe ic (\focusw -> if focusw == win 
                                                   then ac else ic) . W.peek) 
                             `fmap` gets windowset
  (bc',borderc',tc') <- focusColor ow
                           (inactiveColor c, inactiveBorderColor c, inactiveTextColor c) 
                           (activeColor   c, activeBorderColor   c, activeTextColor   c)
  
  -- initialize colors
  bc      <- io $ initColor d bc'
  borderc <- io $ initColor d borderc'
  tc      <- io $ initColor d tc'
  -- pixmax and graphic context
  p       <- io $ createPixmap d tabw wh ht (defaultDepthOfScreen $ defaultScreenOfDisplay d)
  gc      <- io $ createGC d p
  -- draw
  io $ setGraphicsExposures d gc False
  io $ fillDrawable d p gc borderc bc 1 wh ht
  io $ setFont d gc (fontFromFontStruct fs)
  let name           = shrinkWhile shrinkText (\n -> textWidth fs n >
                                           fromIntegral wh - fromIntegral (ht `div` 2)) (show nw)
      width          = textWidth   fs name
      (_,asc,desc,_) = textExtents fs name
      y              = fromIntegral $ ((ht - fromIntegral (asc + desc)) `div` 2) + fromIntegral asc
      x              = fromIntegral (wh `div` 2) - fromIntegral (width `div` 2)
  io $ printString d p gc tc bc x y name
  io $ copyArea    d p tabw gc 0 0 wh ht 0 0
  io $ freePixmap  d p
  io $ freeGC      d gc

destroyTabs :: [Window] -> X ()
destroyTabs w = do
  d <- asks display
  io $ mapM_ (destroyWindow d) w

hideTabs :: [Window] -> X ()
hideTabs w = do
  d <- asks display
  io $ mapM_ (unmapWindow d) w

showTabs :: [Window] -> X ()
showTabs w = do
  d <- asks display
  io $ mapM_ (mapWindow d) w

shrink :: TConf -> Rectangle -> Rectangle
shrink c (Rectangle x y w h) = 
    Rectangle x (y + fromIntegral (tabSize c)) w (h - fromIntegral (tabSize c))

type Shrinker = String -> [String]

shrinkWhile :: Shrinker -> (String -> Bool) -> String -> String
shrinkWhile sh p x = sw $ sh x
    where sw [n] = n
          sw [] = ""
          sw (n:ns) | p n = sw ns
                    | otherwise = n

shrinkText :: Shrinker
shrinkText "" = [""]
shrinkText cs = cs : shrinkText (init cs)
