require 'rnn'
require 'warp_ctc'
require 'math'

local cmd = torch.CmdLine()
cmd:text()
cmd:text('Option:')
cmd:option('-maxepochs', 1000, 'maximum epochs')
cmd:option('-dataset', 'fullset.dat', 'fullset for training and validation')
cmd:option('-splitrate', 0.8, 'split rate for fullset, trainset and validset')
cmd:option('-gpuid', -1, 'which GPU to use, -1 means using CPU')
cmd:text()
local opt = cmd:parse(arg or {})

-- loading input
local fullset = torch.load(opt.dataset)
local trainset = {}
local validset = {}
trainset.size = math.floor(fullset.size * opt.splitrate)
validset.size = fullset.size - trainset.size
trainset.inputs = fullset.inputs[{{1, trainset.size}, {}, {}}]
trainset.targets = fullset.targets[{{1, trainset.size}, {}}]
validset.inputs = fullset.inputs[{{trainset.size + 1, fullset.size}, {}, {}}]
validset.targets = fullset.targets[{{trainset.size + 1, fullset.size}, {}}]
print(string.format('train size = %d, valid size = %d', trainset.size, validset.size))

-- building model
local vocab_size = 10 + 1   -- for this problem, 0-9 plus ' '(blank)

local model = nn.Sequential()
model:add(nn.SplitTable(1))

local hiddensize = {31, 256}
local inputsize = hiddensize[1]

for i = 2, #hiddensize do
    local rnn = nn.FastLSTM(inputsize, hiddensize[i])
    model:add(nn.Sequencer(rnn))
    model:add(nn.Sequencer(nn.Dropout(0.5)))
    inputsize = hiddensize[i]
end

model:add(nn.Sequencer(nn.Linear(hiddensize[#hiddensize], vocab_size)))
model:add(nn.JoinTable(1))

if opt.gpuid >= 0 then
    require 'cutorch'
    require 'cunn'
    cutorch.setDevice(opt.gpuid + 1)
    local free, total = cutorch.getMemoryUsage(opt.gpuid + 1)
    print(string.format("GPU %d has %dM memory left, with %dM totally", opt.gpuid + 1,
            free/1000000, total/1000000))
    trainset.inputs = trainset.inputs:cuda()
    trainset.targets = trainset.targets:cuda()
    validset.inputs = validset.inputs:cuda()
    validset.targets = validset.targets:cuda()
    model = model:cuda()
end

print(model)

for k, param in ipairs(model:parameters()) do
    param:uniform(-0.1, 0.1)
end

-- decoder function
function maxdecoder(output)
    local _, index = output:max(2)
    index = index:resize(index:size(1))
    local predtarget = {}
    for i = 1, index:size()[1] do
        if index[i] ~= predtarget[#predtarget] then
            predtarget[#predtarget + 1] = index[i]
        end
    end
    local predstr = '#'
    for i, num in ipairs(predtarget) do
        if num == 1 then
            predstr = predstr .. '_'
        else
            predstr = predstr .. tostring(num-2)
        end
    end
    return predstr .. '#'
end

-- training
function train(learningRate)
    local total_loss = 0
    local shuffle = torch.randperm(trainset.size)
    local batchsize = 50
    local totalsize = math.ceil(trainset.size / batchsize)
    local count = 1
    for t = 1, trainset.size, batchsize do
        xlua.progress(count, totalsize)
        count = count + 1
        local actualsize = math.min(batchsize + t - 1, trainset.size) - t + 1
        local inputs = torch.Tensor(actualsize, 58, 31):fill(0)
        if opt.gpuid >= 0 then
            inputs = inputs:cuda()
        end
        local targets = {}
        local sizes = {}
        for i = t, t+actualsize-1 do
            inputs[i - t + 1] = trainset.inputs[shuffle[i]]:t()
            local targetstr = trainset.targets[shuffle[i]]
            local target = {}
            for j = 1, targetstr:size(1) do
                table.insert(target, targetstr[j])
            end
            table.insert(targets, target)
            table.insert(sizes, 58)
        end
        local outputs = model:forward(inputs)
        local acts = outputs:clone():fill(0)
        for i = 1, actualsize do
            for j = 1, 58 do
                acts[i + actualsize * (j - 1)] = outputs[j + 58 * (i - 1)]
            end
        end
        local grads = outputs:clone():fill(0)
        local losses = {}
        if opt.gpuid >= 0 then
            acts = acts:cuda()
            grads = grads:cuda()
            losses = gpu_ctc(acts, grads, targets, sizes)
        else
            acts = acts:float()
            grads = grads:float()
            losses = cpu_ctc(acts, grads, targets, sizes)
        end
        local gradients = grads:clone():fill(0)
        for i = 1, actualsize do
            for j = 1, 58 do
                gradients[j + 58 * (i - 1)] = grads[i + actualsize * (j - 1)]
            end
        end
        for i = 1, #losses do
            total_loss = total_loss + losses[i]
        end
        model:zeroGradParameters()
        model:backward(inputs, gradients)
        model:updateGradParameters(0.9)
        model:updateParameters(learningRate)
    end

    return total_loss / trainset.size
end

-- evaluating
function eval()
    local total_loss = 0
    local shuffle = torch.randperm(validset.size)
    local batchsize = 50
    for t = 1, validset.size, batchsize do
        local actualsize = math.min(batchsize + t - 1, validset.size) - t + 1
        local inputs = torch.Tensor(actualsize, 58, 31):fill(0)
        if opt.gpuid >= 0 then
            inputs = inputs:cuda()
        end
        local targets = {}
        local sizes = {}
        for i = t, t+actualsize-1 do
            inputs[i-t+1] = validset.inputs[shuffle[i]]:t()
            local targetstr = validset.targets[shuffle[i]]
            local target = {}
            for j = 1, targetstr:size(1) do
                table.insert(target, targetstr[j])
            end
            table.insert(targets, target)
            table.insert(sizes, 58)
        end
        local outputs = model:forward(inputs)
        local acts = outputs:clone():fill(0)
        for i = 1, actualsize do
            for j = 1, 58 do
                acts[i + actualsize * (j - 1)] = outputs[j + 58 * (i - 1)]
            end
        end

        local grads = torch.Tensor() -- don't need gradients for validation here
        local losses = {}

        if opt.gpuid >= 0 then
            acts = acts:cuda()
            grads = grads:cuda()
            losses = gpu_ctc(acts, grads, targets, sizes)
        else
            acts = acts:float()
            grads = grads:float()
            losses = cpu_ctc(acts, grads, targets, sizes)
        end
        for i = 1, #losses do
            total_loss = total_loss + losses[i]
        end
    end
    return total_loss / validset.size
end

do
    for epoch = 1, opt.maxepochs do
        local learningRate = 0.001 - (0.001 - 0.0000001) / opt.maxepochs * epoch
        model:training()
        local loss = train(learningRate)
        model:evaluate()
        local v_loss = eval()
        print(string.format('epoch = %d, loss = %.4f, v_loss = %.4f', epoch, loss, v_loss))
        local inputs = torch.Tensor(1, 58, 31)
        if opt.gpuid >= 0 then
            inputs = inputs:cuda()
        end
        inputs[1] = trainset.inputs[1]:t()
        local output = model:forward(inputs)
        print('predction = ', maxdecoder(output))
    end
end
