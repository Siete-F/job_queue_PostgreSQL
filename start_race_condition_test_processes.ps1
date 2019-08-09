.\venv\Scripts\activate
# pipe 1
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\race_condition_testing.py", "process_1"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\race_condition_testing.py", "process_2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\race_condition_testing.py", "process_3"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\race_condition_testing.py", "process_4"
