# CLAUDE.md - HikeWise Project Context

## Project Overview
HikeWise is a React Native / Expo study productivity app (originally "The Triage"). It features focus study sessions with timers, AI assistant (Nora), community features, messaging, study rooms, leaderboards, brain mapping, and a premium subscription tier.

## Tech Stack
- **Framework**: React Native 0.81.4 with Expo SDK 54
- **Navigation**: React Navigation v7 (Drawer + Stack + Bottom Tabs)
- **Auth**: Clerk (`@clerk/clerk-expo`) + legacy AuthContext
- **Backend**: Convex (migrating from Supabase)
- **State Management**: React Context (AuthContext, ThemeContext, QRAcceptanceContext)
- **Styling**: React Native StyleSheet + expo-linear-gradient
- **Animations**: react-native-reanimated v4 + Lottie
- **Testing**: Maestro E2E (flows in `maestro/` directory)
- **3D**: Three.js via expo-three (Brain Mapping screen)

## Navigation Architecture
```
RootNavigator (Native Stack)
  ├── Landing (LandingPage - initial screen)
  ├── Auth (AuthNavigator - Stack)
  │     ├── Login
  │     ├── Register
  │     ├── ForgotPassword
  │     ├── ResetPassword
  │     ├── EmailVerification
  │     ├── SignInVerification
  │     └── TwoFactorVerification
  ├── Onboarding (OnboardingNavigator - Stack)
  │     ├── AccountCreation
  │     ├── EmailVerification
  │     ├── ProfileCreation
  │     ├── TrailBuddyOnboarding
  │     ├── FocusSoundSetup
  │     ├── FocusMethodIntro
  │     ├── StudyPreferences
  │     ├── PrivacySettings
  │     └── AppTutorial
  ├── Main (MainNavigator - Drawer, right-side)
  │     ├── Home (HomeScreen)
  │     ├── Community (CommunityScreen)
  │     ├── NoraScreen (AI Assistant)
  │     ├── Bonuses (BonusesScreen)
  │     ├── Results (AnalyticsScreen)
  │     ├── Leaderboard
  │     ├── Profile → ProfileCustomization, PersonalInformation, Education, etc.
  │     ├── Settings → SoundSettings, ThemeSettings, AISettings, NotificationSettings
  │     ├── Shop, Subscription, ProTrekker
  │     ├── SessionHistory, FocusPreparation
  │     ├── SelfDiscoveryQuiz, BrainMapping, Achievements
  │     ├── EBooks, PDFViewer, QRScanner
  │     └── TrailBuddySelection
  ├── StudySessionScreen (fullScreenModal)
  ├── BreakTimerScreen
  ├── SessionReportScreen
  ├── SessionHistory
  ├── PatrickSpeak (fullScreenModal)
  ├── MessageScreen
  └── StudyRoomScreen (fullScreenModal)
```

**Bottom Tabs** (visible): Home, Community, Patrick, Bonuses, Results
**Drawer items**: Home, Community, Nora, Bonuses, Results, Session History, Leaderboard, Profile, Settings, Subscription

## Directory Structure
```
/src
  /components        # Reusable components
  /context           # React Contexts (Auth, Theme, QR)
  /contexts          # Additional contexts
  /data              # Static data
  /hooks             # Custom React hooks
  /navigation        # React Navigation setup
    RootNavigator.tsx
    MainNavigator.tsx
    BottomTabNavigator.tsx
    AuthNavigator.tsx
    OnboardingNavigator.tsx
    types.ts
  /providers         # ConvexClientProvider
  /screens
    /auth            # Login, Register, ForgotPassword, etc.
    /bonuses         # AchievementsScreen
    /main            # All main screens (Home, Community, Nora, etc.)
      /profile       # Profile sub-screens
      /settings      # Settings sub-screens
      /subscription  # Subscription components
    /onboarding      # Onboarding flow screens
    LandingPage.tsx
  /services          # API service layer
  /theme             # Theme constants, premiumTheme
  /utils             # Utilities
/maestro
  /flows
    /discovery       # Maestro discovery flows (find issues)
    /verify          # Maestro verification flows (confirm fixes)
  screenshots.yaml
/directives          # Agent SOPs in Markdown
/execution           # Deterministic Python scripts
/convex              # Convex backend functions
/assets              # Images, fonts, animations
App.tsx              # App entry point
app.json             # Expo config (bundle: com.hikewise.app)
```

## Critical Rules for Agent
1. **NEVER modify files outside the worktree**
2. **NEVER push to any remote branch** - all commits stay local
3. **NEVER delete existing test files** without explicit approval
4. **Run tests after changes**: `maestro test maestro/flows/` for E2E tests
5. **Keep commits atomic** - one logical change per commit
6. **Update claude-progress.txt** after each task
7. If unsure about a change, **document it and move on**

## Navigation Rules
- Drawer is on the RIGHT side (swipe disabled, must tap menu icon)
- All swipe gestures DISABLED in Root Stack (gestureEnabled: false)
- Back navigation via React Navigation stack, NOT custom back handlers
- Use `navigation.goBack()` for back, `navigation.navigate()` for forward
- Root uses fade animation (280ms duration)
- Auth flow: Landing → Auth → Login/Register → (Onboarding if new) → Main

## Key Bundle/App IDs
- **iOS**: `com.hikewise.app` (build #15)
- **Android**: `com.hikewise.app` (versionCode 19)
- **EAS Project**: `8c921112-45b4-48cf-91c3-a1326803d706`
- **GitHub**: `Holajack/thetriage`

## Common Issues to Watch For
- Back button going to Landing instead of previous screen (Root Stack misconfiguration)
- Drawer opening from wrong side (should be RIGHT only via menu button)
- Clerk auth state not syncing with legacy AuthContext
- Three.js OBJLoader URL error (fixed with React.lazy in BrainMappingScreen)
- Focus session timer not persisting when app backgrounds
- Missing testID on components (breaks Maestro tests)

## How to Test
```bash
# Start the dev server
npx expo start

# Run Maestro discovery tests
maestro test maestro/flows/discovery/

# Run Maestro verification tests
maestro test maestro/flows/verify/

# Run specific test
maestro test maestro/flows/verify/navigation-back-button.yaml

# Interactive element inspector
maestro studio

# Python test runner
python execution/maestro_test_runner.py --action run --flows maestro/flows/verify
```

## Commit Message Convention
- `fix: description` for bug fixes
- `feat: description` for new features
- `test: description` for adding/updating tests
- `chore: description` for maintenance tasks
- `refactor: description` for code restructuring
