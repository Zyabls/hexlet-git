#3
#1
#0
#9
n = int(input())
arr=[]
c=0
for i in range(n):
    arr.append(int(input()))
for i in range(n):
    if arr[i]%2==0:
        c+=1
print(c)