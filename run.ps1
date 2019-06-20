.\venv\Scripts\activate
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "second_process", "1.5.2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "wearing_compliance", "1.5.2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "classification", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "classification", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "classification", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "assigner", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "movemonitor", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "first_process", "1.9.2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "second_process", "2.2.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call.py", "third_process", "5.3.0"

