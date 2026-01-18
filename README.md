# VMGuard — Host-Safe Virtual Machine Shutdown Framework
**Version:** Git Baseline v1.0  
**Author:** javaboy-vk  
**Platform:** Windows 10/11, Windows Server  

---

## 1. Overview

VMGuard is a multi-component Windows shutdown coordination framework designed to guarantee a **best-effort, orderly shutdown of a protected VMware virtual machine** before the Windows host enters deep teardown.

VMGuard is engineered to:

- Avoid polling architectures  
- Avoid fragile timing dependencies  
- Survive partial service teardown  
- Operate correctly across shutdown, restart, and logoff paths  
- Favor kernel-level signaling and OS-native lifecycle hooks  

---

## 2. Architecture

VMGuard consists of four cooperating layers:

### A. VMGuard Guard (Windows Service, LocalSystem)
Core coordinator. Owns the named STOP kernel event and releases the shutdown sequence.

Location:
```
guard\vmguard-service.ps1
```

Responsibilities:
- Create and block on STOP kernel event  
- Trigger user-context scheduled task  
- Never block Windows shutdown  
- Always exit STOP cleanly  

---

### B. VMGuard Watcher (Windows Service, LocalSystem)
Runtime state observer and early warning layer.

Location:
```
watcher\vm-watcher.ps1
```

Responsibilities:
- Monitor VM presence and runtime flags  
- Maintain state signals  
- Provide early detection and logging  

---

### C. Preshutdown Sentinel (.NET Windows Service)
Registered with Windows Preshutdown mechanism. Fires before SCM teardown.

Location:
```
Preshutdown_Sentinel\src\
```

Responsibilities:
- Receive Windows preshutdown callback  
- Trigger Guard STOP release path  
- Survive deep service shutdown phase  

Built and installed using:
```
Preshutdown_Sentinel\build.cmd
install\install-preshutdown-sentinel-service.cmd
```

---

### D. Host Shutdown Interceptor (Scheduled Task)
Runs in user context during host shutdown/logoff.

Location:
```
guard\vmguard-host-shutdown-interceptor.ps1
install\vmguard-host-shutdown-interceptor-task.xml
```

Responsibilities:
- Fire Guard STOP signaling before session teardown  
- Bridge service → user context  
- Reduce VMware race conditions  

---

## 3. Directory Layout

```
VMGuard\
  common\              Shared logging and shutdown primitives
  guard\               Guard service and shutdown logic
  watcher\             Watcher service
  install\             Installers and service wiring
  dev-harness\         Engineering tools (non-production)
  Preshutdown_Sentinel\ .NET preshutdown service (source + build)
  exe\                 Apache Procrun runtime
  flags\               Runtime state (not versioned)
  logs\                Runtime logs (not versioned)
```

---

## 4. Installation Order (Clean Machine)

Run all installers elevated.

1. Guard Service  
```
install\install-guard-service.cmd
```

2. Watcher Service  
```
install\install-watcher-service.cmd
```

3. Preshutdown Sentinel  
```
Preshutdown_Sentinel\build.cmd
install\install-preshutdown-sentinel-service.cmd
```

4. Host Shutdown Interceptor Task  
```
install\install-vmguard-host-shutdown-interceptor.cmd
```

---

## 5. Control and Testing

Manual STOP triggers:
```
install\vmguard-guard-stop.cmd
install\vmguard-watcher-stop.cmd
```

Developer tools:
```
dev-harness\vmguard-dev-menu.cmd
dev-harness\vmguard-manual-stop.ps1
dev-harness\vmguard-healthcheck.ps1
```

---

## 6. Git Model

This repository contains **only source, installers, and architectural assets.**

Not versioned:
- logs  
- runtime flags  
- bin/obj  
- generated output  
- machine-specific state  

The Git repository defines what VMGuard *is*.  
The machine defines how VMGuard *runs*.

---

## 7. Design Principles

- Event-driven, not polling  
- Kernel-level coordination  
- Best-effort STOP semantics  
- Never block Windows shutdown  
- Explicit lifecycle boundaries  
- Deterministic installs  
- Fully portable directory layout  

---

## 8. Status

VMGuard is in active engineering evolution.  
This Git Baseline marks the first formally curated architecture snapshot.