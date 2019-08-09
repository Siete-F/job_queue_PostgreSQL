.\venv\Scripts\activate
# pipe 1
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\Simultanious_calls_test.py", "process_1"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\Simultanious_calls_test.py", "process_2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\Simultanious_calls_test.py", "process_3"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\Simultanious_calls_test.py", "process_4"
