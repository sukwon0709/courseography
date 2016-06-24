{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}


module WebParsing.UtsgJsonParser
     (insertAllCourses) where

import Data.Aeson ((.:), (.:?), decode, FromJSON(..), Value(..))
import Data.List
import Database.Tables
import WebParsing.PrerequisiteParsing
import Data.Maybe
import Data.String
import Control.Monad
import Database.Persist.Sqlite (runSqlite, insertMany_, insert_)
import qualified Data.HashMap.Lazy as M
import qualified Data.Text as T
import Config (databasePath)
import Network.HTTP.Conduit (simpleHttp)
import Control.Applicative ((<$>), (<*>))

import Data.Traversable
import Data.Aeson.Types
import qualified Data.HashMap.Strict as HM

 -- | URL to UofT courses (stored as JSON string)
jsonURL :: String
jsonURL = "https://timetable.iit.artsci.utoronto.ca/api/courses?code=csc"

-- | Converts 24-hour time into a double
-- | Assumes times are rounded to the nearest hour
getHourVal :: String -> Double
getHourVal time = (read $ take 2 time :: Double) + (/) (read $ drop 3 time :: Double) 60

-- | Converts a weekday into a double
-- | Monday to Friday becomes 0.0 to 4.0
getDayVal :: String -> Double
getDayVal day = case day of
                    "MO" -> 0.0
                    "TU" -> 1.0
                    "WE" -> 2.0
                    "TH" -> 3.0
                    "FR" -> 4.0

-- | Takes a day and start/end times then generates a set of 30-minute timeslots
getTimeSlots :: String -> String -> String -> [Time]
getTimeSlots day start end = do
    let dayDbl = getDayVal day
        startDbl = getHourVal start
        endDbl = getHourVal end
    [Time [dayDbl, timeDbl] | timeDbl <- [startDbl, (startDbl + 0.5) .. (endDbl - 0.5)]]

 -- | Decode JSON string into hash map object
getJSON :: IO (Maybe DB)
getJSON = do
  resp <- simpleHttp jsonURL
  return $ (decode resp :: Maybe DB)

newtype Test = Test T.Text
    deriving Show

newtype Meeting = Meeting [(Either Lecture Test)] -- Tutorial
  deriving Show

zipTimes :: [T.Text] -> [T.Text] -> [T.Text] -> [[Time]]
zipTimes [""] [""] [""] = [[]]
zipTimes days starts ends = zipWith3 (\day start end -> getTimeSlots (T.unpack day) (T.unpack start) (T.unpack end))
                                      days
                                      starts
                                      ends

zipTimeStr :: [T.Text] -> [T.Text] -> [T.Text] -> [String]
zipTimeStr = zipWith3 (\day start end -> intercalate " " [(T.unpack day), (T.unpack start), (T.unpack end)])

zipInstructors :: [T.Text] -> [T.Text] -> [String]
zipInstructors = zipWith (\firstN lastN -> intercalate " " [(T.unpack firstN), T.unpack lastN])

lookupVal :: Value -> T.Text -> [T.Text]
lookupVal (Array _) _ = [""]
lookupVal (Object lst) val = map (\val -> case val of
                                            (String s) -> s
                                            _ -> "") $
                                 map (\(Object o) -> fromMaybe (String "") $ HM.lookup val o) $
                                    map snd $ HM.toList lst

instance FromJSON Meeting where
    parseJSON = withObject "Meeting" $ \o -> do
      code <- o .: "code"
      session <- o .: "section"
      meetings <- (o .: "meetings" :: Parser (HM.HashMap String (HM.HashMap String Value)))
      return $ Meeting $ map (\(section, sectionHash) -> let (String cap) = fromMaybe (String "-1") $ HM.lookup "enrollmentCapacity" sectionHash
                                                             (String wait') = fromMaybe (String "-1") $ HM.lookup "waitlist" sectionHash
                                                             schedule = fromJust $ HM.lookup "schedule" sectionHash
                                                             dayLst = lookupVal schedule "meetingDay"
                                                             startLst = lookupVal schedule "meetingStartTime"
                                                             endLst = lookupVal schedule "meetingEndTime"
                                                             timesStr = zipTimeStr dayLst startLst endLst
                                                             instructors = fromJust $ HM.lookup "instructors" sectionHash
                                                             instructorStr = zipInstructors (lookupVal instructors "firstName") (lookupVal instructors "lastName")
                                                             wait = if (T.unpack wait') == "Y" then 0 else -1
                                                             enrol = 0
                                                             extra = 0
                                                         in
                                                         if (take 3 section) == "LEC"
                                                         then Left $ Lecture code
                                                                             session
                                                                             (T.pack section)
                                                                             (concat $ zipTimes dayLst startLst endLst)
                                                                             (read $ T.unpack cap :: Int)
                                                                             (T.pack $ intercalate ", " instructorStr)
                                                                             enrol
                                                                             wait
                                                                             extra
                                                                             (T.pack $ intercalate ", " timesStr)
                                                        else Right $ Test (T.pack $ intercalate ", " instructorStr ++ (T.unpack code)))
                             (HM.toList meetings)

instance FromJSON Courses where
  parseJSON = withObject "Courses" $ \o -> do
    code <- o .: "code"
    title  <- o .: "courseTitle"
    description  <- o .: "courseDescription"
    meetingsObj <- (o .: "meetings" :: Parser (HM.HashMap String Value))
    let manualTutorialEnrolment = elem "TUT" $ map (take 3) $ M.keys meetingsObj
        manualPracticalEnrolment = elem "PRA" $ map (take 3) $ M.keys meetingsObj
    prereqString <- o .: "prerequisite"
    let prereqs = parsePrerequisites $ Just prereqString
    exclusions <- o .: "exclusion"
    breadth <- o .: "breadthCategories"
    distribution <- o .: "distributionCategories"
    coreqs <- o .: "corequisite"
    let videoUrls = []
    return $ Courses code
                     (Just title)
                     (Just description)
                     (Just manualTutorialEnrolment)
                     (Just manualPracticalEnrolment)
                     prereqs
                     exclusions
                     (Just breadth)
                     (Just distribution)
                     (Just prereqString)
                     (Just coreqs)
                     videoUrls


newtype DB = DB (HM.HashMap String Meeting)
  deriving Show

instance FromJSON DB where
  parseJSON val = DB <$> parseJSON val

insertAllCourses = do
    coursesLst <- getJSON
    case coursesLst of
            --(Just (DB courses)) -> runSqlite databasePath $ insertMany_ $ HM.elems courses
            (Just (DB courses)) -> print $ HM.elems courses
            otherwise -> print "Failed to insert courses"
