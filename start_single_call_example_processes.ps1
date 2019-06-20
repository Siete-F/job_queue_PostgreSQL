.\venv\Scripts\activate
# pipe 1
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "wearing_compliance", "1.5.2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "classification", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "classification", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "classification", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "assigner", "1.0.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "movemonitor", "1.0.0"

# pipe 2  (contains configurations)
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "first_process", "1.9.2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "second_process", "2.2.0"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "third_process", "5.3.0"

# pipe 4
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "sumarizing_results", "1.5.2"
Start-Process -FilePath python.exe -WindowStyle normal -ArgumentList ".\single_call_job_queue.py", "creating_report", "1.0.0"

